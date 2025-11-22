import 'dart:async';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import 'services/face_embedding_service.dart';
import 'services/web_camera_service.dart';

class AttendanceSessionConfig {
  const AttendanceSessionConfig({
    required this.classId,
    required this.subjectCode,
    required this.subjectName,
    required this.dayOfWeek,
    required this.start,
    required this.end,
    this.section,
    this.term,
    this.location,
  });

  final String classId;
  final String subjectCode;
  final String subjectName;
  final String? section;
  final String? term;
  final String? location;
  final int dayOfWeek;
  final TimeOfDay start;
  final TimeOfDay end;
}

class AttendanceSessionPage extends StatefulWidget {
  const AttendanceSessionPage({super.key, required this.config});

  static const String routeName = '/attendance-session';

  final AttendanceSessionConfig config;

  @override
  State<AttendanceSessionPage> createState() => _AttendanceSessionPageState();
}

class _AttendanceSessionPageState extends State<AttendanceSessionPage> {
  static const double _similarityThreshold = 0.78;
  static const Duration _captureCooldown = Duration(seconds: 2);
  static const Duration _duplicateCaptureCooldown = Duration(seconds: 10);

  final FaceEmbeddingService _embeddingService = FaceEmbeddingService.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  CameraController? _cameraController;
  FaceDetector? _faceDetector;
  WebCameraService? _webCameraService;
  Timer? _webCaptureTimer;

  bool _isProcessingFrame = false;
  bool _captureEnabled = true;
  bool _isEndingSession = false;
  bool _initializing = true;
  String? _statusMessage;
  String? _sessionDocId;
  bool _sessionClosed = false;
  DateTime? _lastCaptureTime;

  List<_RecognizedStudent> _roster = <_RecognizedStudent>[];
  final List<_AttendanceCapture> _recentCaptures = <_AttendanceCapture>[];
  final Map<String, String> _recordedStatuses = <String, String>{};
  final Map<String, DateTime> _lastStudentCaptureTimes = <String, DateTime>{};
  final ScrollController _captureListController = ScrollController();

  @override
  void initState() {
    super.initState();
    if (!kIsWeb) {
      _faceDetector = FaceDetector(
        options: FaceDetectorOptions(
          performanceMode: FaceDetectorMode.accurate,
          enableLandmarks: false,
          enableContours: false,
          enableTracking: false,
        ),
      );
    }
    _initializeSession();
  }

  Future<void> _initializeSession() async {
    setState(() {
      _initializing = true;
      _statusMessage = 'Preparing attendance session...';
    });

    try {
      await _embeddingService.initialize();
      await _ensureSessionDocument();
      await _loadRosterEmbeddings();
      if (kIsWeb) {
        await _initializeWebCamera();
      } else {
        await _initializeDeviceCamera();
      }
      if (!mounted) return;
      setState(() {
        _initializing = false;
        _statusMessage = 'Session live. Keep students centered for best recognition results.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _initializing = false;
        _captureEnabled = false;
        _statusMessage = 'Session initialization failed: $error';
      });
    }
  }

  Future<void> _ensureSessionDocument() async {
    if (_sessionDocId != null) return;
    final User? user = FirebaseAuth.instance.currentUser;
    final DocumentReference<Map<String, dynamic>> doc =
        _firestore.collection('attendanceSessions').doc();
    await doc.set(<String, dynamic>{
      'classId': widget.config.classId,
      'subjectCode': widget.config.subjectCode,
      'subjectName': widget.config.subjectName,
      'section': widget.config.section,
      'term': widget.config.term,
      'location': widget.config.location,
      'dayOfWeek': widget.config.dayOfWeek,
      'startHour': widget.config.start.hour,
      'startMinute': widget.config.start.minute,
      'endHour': widget.config.end.hour,
      'endMinute': widget.config.end.minute,
      'instructorId': user?.uid,
      'instructorEmail': user?.email,
      'status': 'active',
      'startedAt': FieldValue.serverTimestamp(),
      'createdAt': FieldValue.serverTimestamp(),
    });
    _sessionDocId = doc.id;
  }

  Future<void> _loadRosterEmbeddings() async {
    final QuerySnapshot<Map<String, dynamic>> snapshot = await _firestore
        .collection('users')
        .where('role', isEqualTo: 'student')
        .get();
    final List<_RecognizedStudent> roster = snapshot.docs
        .map(_RecognizedStudent.fromDocument)
        .whereType<_RecognizedStudent>()
        .toList();
    setState(() => _roster = roster);
  }

  Future<void> _initializeWebCamera() async {
    final WebCameraService service = WebCameraService();
    await service.initialize();
    if (!mounted) {
      service.dispose();
      return;
    }
    setState(() => _webCameraService = service);
    _webCaptureTimer = Timer.periodic(
      const Duration(milliseconds: 900),
      (_) => _processWebFrame(),
    );
  }

  Future<void> _initializeDeviceCamera() async {
    final List<CameraDescription> cameras = await availableCameras();
    if (cameras.isEmpty) {
      throw StateError('No camera devices detected.');
    }
    final CameraDescription camera = cameras.firstWhere(
      (CameraDescription description) => description.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );
    final CameraController controller = CameraController(
      camera,
      ResolutionPreset.medium,
      imageFormatGroup: ImageFormatGroup.yuv420,
      enableAudio: false,
    );
    await controller.initialize();
    await controller.startImageStream(_processCameraImage);
    if (!mounted) {
      await controller.dispose();
      return;
    }
    setState(() => _cameraController = controller);
  }

  Future<void> _processCameraImage(CameraImage image) async {
    if (!_captureEnabled || _isProcessingFrame || !_embeddingService.isReady) {
      return;
    }
    final FaceDetector? detector = _faceDetector;
    if (detector == null) {
      return;
    }
    if (_isWithinCooldown()) {
      return;
    }
    _isProcessingFrame = true;
    _lastCaptureTime = DateTime.now();
    try {
      final InputImage inputImage = _buildInputImage(image);
      final List<Face> faces = await detector.processImage(inputImage);
      if (faces.isEmpty) {
        _updateStatus('No face detected. Ask the student to step closer.');
      } else {
        final Rect bbox = faces.first.boundingBox;
        final List<double> embedding =
            await _embeddingService.generateEmbedding(image, bbox);
        await _handleEmbeddingCapture(embedding);
      }
    } catch (error) {
      debugPrint('Camera frame processing error: $error');
    } finally {
      _isProcessingFrame = false;
    }
  }

  Future<void> _processWebFrame() async {
    if (!kIsWeb || !_captureEnabled || _isProcessingFrame || !_embeddingService.isReady) {
      return;
    }
    if (_isWithinCooldown()) {
      return;
    }
    _isProcessingFrame = true;
    _lastCaptureTime = DateTime.now();
    try {
      final WebCameraFrame? frame = await _webCameraService?.captureFrame();
      if (frame == null) return;
      final Size size = frame.size;
      final double cropSize = math.min(size.width, size.height) * 0.7;
      final Rect bbox = Rect.fromLTWH(
        (size.width - cropSize) / 2,
        (size.height - cropSize) / 2,
        cropSize,
        cropSize,
      );
      final List<double> embedding = await _embeddingService
          .generateEmbeddingFromImage(frame.image, bbox);
      await _handleEmbeddingCapture(embedding);
    } catch (error) {
      debugPrint('Web frame processing error: $error');
    } finally {
      _isProcessingFrame = false;
    }
  }

  bool _isWithinCooldown() {
    final DateTime? last = _lastCaptureTime;
    if (last == null) {
      return false;
    }
    return DateTime.now().difference(last) < _captureCooldown;
  }

  Future<void> _handleEmbeddingCapture(List<double> embedding) async {
    final _MatchResult result = _matchEmbedding(embedding);
    final DateTime captureTime = DateTime.now();
    if (result.student != null &&
        _shouldThrottleStudentCapture(result.student!.userId, captureTime)) {
      return;
    }
    _recordLocalCapture(result, captureTime);
    await _persistCapture(result, embedding, captureTime);
  }

  _MatchResult _matchEmbedding(List<double> embedding) {
    if (_roster.isEmpty) {
      return _MatchResult(embedding: embedding);
    }
    _RecognizedStudent? bestCandidate;
    double bestSimilarity = -1;
    for (final _RecognizedStudent student in _roster) {
      final double similarity = _cosineSimilarity(embedding, student.embedding);
      if (similarity > bestSimilarity) {
        bestSimilarity = similarity;
        bestCandidate = student;
      }
    }
    if (bestCandidate == null || bestSimilarity < _similarityThreshold) {
      return _MatchResult(embedding: embedding);
    }
    final double confidence = _normalizeConfidence(bestSimilarity);
    return _MatchResult(
      embedding: embedding,
      student: bestCandidate,
      similarity: bestSimilarity,
      confidence: confidence,
    );
  }

  void _recordLocalCapture(_MatchResult result, DateTime captureTime) {
    final _AttendanceCapture capture = _AttendanceCapture(
      timestamp: captureTime,
      matchDisplayName: result.student?.displayName,
      confidence: result.confidence,
    );
    setState(() {
      _recentCaptures.insert(0, capture);
      if (_recentCaptures.length > 6) {
        _recentCaptures.removeLast();
      }
      if (result.student != null) {
        _statusMessage = 'Recognized ${result.student!.displayName} '
            '(${_formatConfidence(result.confidence!)})';
      } else {
        _statusMessage = 'Face detected but no match found in roster.';
      }
    });
  }

  Future<void> _persistCapture(_MatchResult result, List<double> embedding, DateTime captureTime) async {
    final String? sessionId = _sessionDocId;
    if (sessionId == null) {
      return;
    }
    final String? attendanceStatus = result.student == null
        ? null
        : _classifyAttendanceStatus(captureTime);
    final DocumentReference<Map<String, dynamic>> sessionRef =
        _firestore.collection('attendanceSessions').doc(sessionId);
    await sessionRef.collection('captures').add(<String, dynamic>{
      'capturedAt': FieldValue.serverTimestamp(),
      'capturedAtLocal': captureTime.toIso8601String(),
      'matchUserId': result.student?.userId,
      'matchDisplayName': result.student?.displayName,
      'confidence': result.confidence,
      'similarity': result.similarity,
      'embedding': embedding,
      'attendanceStatus': attendanceStatus,
    });
    if (result.student != null) {
      await sessionRef.collection('attendees').doc(result.student!.userId).set(<String, dynamic>{
        'displayName': result.student!.displayName,
        'firstCapturedAt': FieldValue.serverTimestamp(),
        'lastCapturedAt': FieldValue.serverTimestamp(),
        'confidence': result.confidence,
        'status': attendanceStatus,
        'statusComputedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      await _updateClassAttendanceStats(
        studentId: result.student!.userId,
        newStatus: attendanceStatus,
      );
    }
    await sessionRef.update(<String, dynamic>{
      'lastCaptureAt': FieldValue.serverTimestamp(),
    });
  }

  bool _shouldThrottleStudentCapture(String studentId, DateTime captureTime) {
    final DateTime? lastCapture = _lastStudentCaptureTimes[studentId];
    if (lastCapture != null &&
        captureTime.difference(lastCapture) < _duplicateCaptureCooldown) {
      return true;
    }
    _lastStudentCaptureTimes[studentId] = captureTime;
    return false;
  }

  String _classifyAttendanceStatus(DateTime captureTime) {
    final AttendanceSessionConfig config = widget.config;
    final DateTime startDateTime = _dateWithTime(captureTime, config.start);
    DateTime endDateTime = _dateWithTime(captureTime, config.end);
    if (endDateTime.isBefore(startDateTime)) {
      endDateTime = endDateTime.add(const Duration(days: 1));
    }
    final Duration totalDuration = endDateTime.difference(startDateTime);
    if (totalDuration.inMinutes <= 0) {
      return 'present';
    }
    final Duration tardyWindow = Duration(
      milliseconds: (totalDuration.inMilliseconds * 0.25).round(),
    );
    final DateTime tardyThreshold = startDateTime.add(tardyWindow);
    return captureTime.isAfter(tardyThreshold) ? 'late' : 'present';
  }

  DateTime _dateWithTime(DateTime reference, TimeOfDay time) {
    return DateTime(reference.year, reference.month, reference.day, time.hour, time.minute);
  }

  Future<void> _updateClassAttendanceStats({
    required String studentId,
    required String? newStatus,
  }) async {
    if (newStatus == null || newStatus.isEmpty) {
      return;
    }
    final String? previousStatus = _recordedStatuses[studentId];
    if (previousStatus == newStatus) {
      return;
    }
    final String classId = widget.config.classId;
    if (classId.isEmpty) {
      return;
    }
    final String? incrementField = _counterFieldForStatus(newStatus);
    if (incrementField == null) {
      return;
    }
    final DocumentReference<Map<String, dynamic>> statsRef = _firestore
        .collection('classes')
        .doc(classId)
        .collection('attendanceStats')
        .doc(studentId);
    final Map<String, Object?> updateData = <String, Object?>{
      incrementField: FieldValue.increment(1),
      'lastStatus': newStatus,
      'lastUpdated': FieldValue.serverTimestamp(),
    };
    final String? decrementField = previousStatus == null
        ? null
        : _counterFieldForStatus(previousStatus);
    if (decrementField != null && decrementField != incrementField) {
      updateData[decrementField] = FieldValue.increment(-1);
    }
    try {
      await statsRef.set(updateData, SetOptions(merge: true));
      _recordedStatuses[studentId] = newStatus;
    } catch (error) {
      debugPrint('Failed to update attendance stats: $error');
    }
  }

  String? _counterFieldForStatus(String status) {
    switch (status) {
      case 'present':
        return 'presentCount';
      case 'late':
        return 'lateCount';
      case 'absent':
        return 'absentCount';
      default:
        return null;
    }
  }
  
  Future<void> _markUncapturedStudentsAbsent() async {
    final List<_RecognizedStudent> roster = _roster;
    if (roster.isEmpty) {
      return;
    }
    final Set<String> countedStudentIds = _recordedStatuses.keys.toSet();
    final Iterable<_RecognizedStudent> uncaptured = roster.where(
      (_RecognizedStudent student) => !countedStudentIds.contains(student.userId),
    );
    for (final _RecognizedStudent student in uncaptured) {
      await _updateClassAttendanceStats(
        studentId: student.userId,
        newStatus: 'absent',
      );
    }
  }

  InputImage _buildInputImage(CameraImage image) {
    final WriteBuffer buffer = WriteBuffer();
    for (final Plane plane in image.planes) {
      buffer.putUint8List(plane.bytes);
    }
    final Uint8List bytes = buffer.done().buffer.asUint8List();
    final Size imageSize = Size(image.width.toDouble(), image.height.toDouble());
    final InputImageRotation rotation = InputImageRotationValue.fromRawValue(
          _cameraController?.description.sensorOrientation ?? 0,
        ) ??
        InputImageRotation.rotation0deg;
    final InputImageFormat format =
        InputImageFormatValue.fromRawValue(image.format.raw) ?? InputImageFormat.nv21;
    final InputImageMetadata metadata = InputImageMetadata(
      size: imageSize,
      rotation: rotation,
      format: format,
      bytesPerRow: image.planes.first.bytesPerRow,
    );
    return InputImage.fromBytes(bytes: bytes, metadata: metadata);
  }

  double _cosineSimilarity(List<double> a, List<double> b) {
    final int length = math.min(a.length, b.length);
    double dot = 0;
    double normA = 0;
    double normB = 0;
    for (int i = 0; i < length; i++) {
      final double valueA = a[i];
      final double valueB = b[i];
      dot += valueA * valueB;
      normA += valueA * valueA;
      normB += valueB * valueB;
    }
    if (normA == 0 || normB == 0) {
      return -1;
    }
    return dot / (math.sqrt(normA) * math.sqrt(normB));
  }

  double _normalizeConfidence(double similarity) {
    final double normalized = (similarity + 1) / 2;
    return normalized.clamp(0, 1);
  }

  void _toggleCapture() {
    setState(() {
      _captureEnabled = !_captureEnabled;
      _statusMessage = _captureEnabled
          ? 'Session live. We will attempt recognition automatically.'
          : 'Session paused. Tap resume to continue recognition.';
    });
  }

  Future<void> _endSession() async {
    if (_isEndingSession) return;
    setState(() => _isEndingSession = true);
    await _completeSessionDocument();
    if (mounted) {
      setState(() => _isEndingSession = false);
      Navigator.of(context).pop(true);
    }
  }

  Future<void> _completeSessionDocument() async {
    if (_sessionClosed) return;
    final String? sessionId = _sessionDocId;
    if (sessionId == null) {
      _sessionClosed = true;
      return;
    }
    try {
      await _firestore.collection('attendanceSessions').doc(sessionId).update(<String, dynamic>{
        'status': 'completed',
        'endedAt': FieldValue.serverTimestamp(),
      });
    } catch (_) {
      // Best-effort update only.
    } finally {
      await _markUncapturedStudentsAbsent();
      _sessionClosed = true;
    }
  }

  void _updateStatus(String message) {
    if (!mounted) return;
    setState(() => _statusMessage = message);
  }

  @override
  void dispose() {
    _cameraController?.stopImageStream();
    _cameraController?.dispose();
    _webCaptureTimer?.cancel();
    _webCameraService?.dispose();
    _faceDetector?.close();
    _captureListController.dispose();
    _completeSessionDocument();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AttendanceSessionConfig config = widget.config;
    final ThemeData theme = Theme.of(context);
    final Widget preview = _buildPreviewPlaceholder();

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? result) async {
        if (didPop) return;
        await _endSession();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Recognition session'),
          actions: <Widget>[
            TextButton.icon(
              onPressed: _isEndingSession ? null : _endSession,
              icon: _isEndingSession
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.stop_circle_outlined),
              label: const Text('End session'),
            ),
          ],
        ),
        body: Column(
          children: <Widget>[
            _SessionHeader(config: config, rosterCount: _roster.length),
            Expanded(
              child: Column(
                children: <Widget>[
                  Expanded(
                    child: Container(
                      margin: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(24),
                        color: theme.colorScheme.surfaceContainerHighest,
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: preview,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Text(
                          _statusMessage ?? 'Initializing session... hold on.',
                          style: theme.textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 8),
                        FilledButton.icon(
                          onPressed: _initializing ? null : _toggleCapture,
                          icon: Icon(_captureEnabled ? Icons.pause_circle : Icons.play_circle),
                          label: Text(_captureEnabled ? 'Pause recognition' : 'Resume recognition'),
                        ),
                      ],
                    ),
                  ),
                  _RecentCapturesList(
                    captures: _recentCaptures,
                    controller: _captureListController,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPreviewPlaceholder() {
    if (kIsWeb) {
      return _webCameraService?.buildPreview() ??
          Center(
            child: _initializing
                ? const CircularProgressIndicator()
                : const Text('Camera initializing...'),
          );
    }
    final CameraController? controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) {
      return Center(
        child: _initializing
            ? const CircularProgressIndicator()
            : const Text('Camera initializing...'),
      );
    }
    return CameraPreview(controller);
  }

  String _formatConfidence(double value) {
    return '${(value * 100).toStringAsFixed(1)}%';
  }
}

class _SessionHeader extends StatelessWidget {
  const _SessionHeader({required this.config, required this.rosterCount});

  final AttendanceSessionConfig config;
  final int rosterCount;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.all(16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('${config.subjectCode} • ${config.subjectName}',
                      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text(_formatSection(config)),
                  const SizedBox(height: 8),
                  Text(_formatSchedule(context, config),
                      style: theme.textTheme.bodySmall),
                ],
              ),
            ),
            Column(
              children: <Widget>[
                const Text('Roster embeddings'),
                Text(rosterCount.toString(),
                    style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _formatSection(AttendanceSessionConfig config) {
    final String sectionLabel = config.section == null ? 'Section TBD' : 'Section ${config.section}';
    final String termLabel = config.term == null ? '' : ' • ${config.term}';
    final String locationLabel = config.location == null ? '' : ' • ${config.location}';
    return '$sectionLabel$termLabel$locationLabel';
  }

  static String _formatSchedule(BuildContext context, AttendanceSessionConfig config) {
    final MaterialLocalizations localizations = MaterialLocalizations.of(context);
    final TimeOfDay start = config.start;
    final TimeOfDay end = config.end;
    final String day = _weekdayLabel(config.dayOfWeek);
    return '$day • ${localizations.formatTimeOfDay(start)} - ${localizations.formatTimeOfDay(end)}';
  }

  static String _weekdayLabel(int day) {
    switch (day) {
      case DateTime.monday:
        return 'Monday';
      case DateTime.tuesday:
        return 'Tuesday';
      case DateTime.wednesday:
        return 'Wednesday';
      case DateTime.thursday:
        return 'Thursday';
      case DateTime.friday:
        return 'Friday';
      case DateTime.saturday:
        return 'Saturday';
      default:
        return 'Sunday';
    }
  }
}

class _RecentCapturesList extends StatelessWidget {
  const _RecentCapturesList({
    required this.captures,
    required this.controller,
  });

  final List<_AttendanceCapture> captures;
  final ScrollController controller;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('Recent captures', style: theme.textTheme.titleMedium),
          if (captures.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text('No captures yet. Position a student in front of the camera to begin.'),
            )
          else
            SizedBox(
              height: 220,
              child: Scrollbar(
                controller: controller,
                thumbVisibility: true,
                child: ListView.separated(
                  controller: controller,
                  itemCount: captures.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (BuildContext context, int index) {
                    final _AttendanceCapture capture = captures[index];
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        capture.matchDisplayName == null ? Icons.help_outline : Icons.verified_user_outlined,
                      ),
                      title: Text(capture.matchDisplayName ?? 'Unrecognized face'),
                      subtitle:
                          Text('Captured at ${TimeOfDay.fromDateTime(capture.timestamp).format(context)}'),
                      trailing: capture.confidence == null
                          ? const Text('No match')
                          : Text('${(capture.confidence! * 100).toStringAsFixed(1)}%'),
                    );
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _AttendanceCapture {
  const _AttendanceCapture({
    required this.timestamp,
    this.matchDisplayName,
    this.confidence,
  });

  final DateTime timestamp;
  final String? matchDisplayName;
  final double? confidence;
}

class _RecognizedStudent {
  const _RecognizedStudent({
    required this.userId,
    required this.displayName,
    required this.embedding,
  });

  final String userId;
  final String displayName;
  final List<double> embedding;

  static _RecognizedStudent? fromDocument(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final Map<String, dynamic> data = doc.data();
    final List<dynamic>? rawEmbedding = data['faceEmbed'] as List<dynamic>?;
    if (rawEmbedding == null || rawEmbedding.isEmpty) {
      return null;
    }
    final List<double> embedding = rawEmbedding
        .map((dynamic value) => (value as num).toDouble())
        .toList(growable: false);
    final String displayName = _resolveDisplayName(data, doc.id);
    return _RecognizedStudent(
      userId: doc.id,
      displayName: displayName,
      embedding: embedding,
    );
  }

  static String _resolveDisplayName(Map<String, dynamic> data, String docId) {
    const List<String> candidateKeys = <String>[
      'displayName',
      'display_name',
      'Full Name',
      'fullName',
      'FullName',
      'full_name',
      'fullname',
      'name',
      'studentName',
      'student_name',
    ];
    for (final String key in candidateKeys) {
      final String? raw = (data[key] as String?)?.trim();
      if (raw != null && raw.isNotEmpty) {
        return raw;
      }
    }
    final int safeLength = math.min(6, docId.length);
    final String fallback = safeLength > 0
        ? docId.substring(0, safeLength).toUpperCase()
        : 'UNKNOWN';
    return 'Student $fallback';
  }
}

class _MatchResult {
  const _MatchResult({
    required this.embedding,
    this.student,
    this.similarity,
    this.confidence,
  });

  final List<double> embedding;
  final _RecognizedStudent? student;
  final double? similarity;
  final double? confidence;
}
