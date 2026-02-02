import 'dart:async';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import 'services/face_embedding_service.dart';
import 'services/web_camera_service.dart';

List<double> _l2NormalizeVector(List<double> v) {
  if (v.isEmpty) return <double>[];
  double sumSquares = 0;
  for (final double x in v) {
    sumSquares += x * x;
  }
  if (sumSquares <= 0) return <double>[];
  final double inv = 1.0 / math.sqrt(sumSquares);
  return v.map((double x) => x * inv).toList(growable: false);
}

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
    this.simulatedClockOffset,
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
  final Duration? simulatedClockOffset;
}

class AttendanceSessionPage extends StatefulWidget {
  const AttendanceSessionPage({super.key, required this.config});

  static const String routeName = '/attendance-session';

  final AttendanceSessionConfig config;

  @override
  State<AttendanceSessionPage> createState() => _AttendanceSessionPageState();
}

class _AttendanceSessionPageState extends State<AttendanceSessionPage> {
  // Recognition is strictly gated to minimize false positives.
  // Tune these with real class data if needed.
  static const double _similarityThreshold = 0.55;
  static const double _similarityMargin = 0.08;
  static const double _confidenceSpan = 0.20;
  static const Duration _captureCooldown = Duration(seconds: 2);
  static const Duration _duplicateCaptureCooldown = Duration(seconds: 10);
  static const Duration _unrecognizedCooldown = Duration(seconds: 4);

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
  DateTime? _lastUnrecognizedTime;
  int _lastRotationCompensation = 0;

  List<_RecognizedStudent> _roster = <_RecognizedStudent>[];
  final List<_AttendanceCapture> _recentCaptures = <_AttendanceCapture>[];
  final Map<String, String> _recordedStatuses = <String, String>{};
  final Map<String, DateTime> _lastStudentCaptureTimes = <String, DateTime>{};
  final Set<String> _capturedStudentIds = <String>{};
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

  DateTime _now() {
    final Duration? offset = widget.config.simulatedClockOffset;
    final DateTime systemNow = DateTime.now();
    return offset == null ? systemNow : systemNow.add(offset);
  }

  Future<void> _initializeSession() async {
    setState(() {
      _initializing = true;
      _statusMessage = 'Preparing attendance session...';
    });

    try {
      // Start long-running initialization tasks early, but do not block
      // opening the camera preview on them. This improves perceived
      // performance (especially when offline and Firestore server calls hang).
      final Future<void> modelInit = _embeddingService.initialize();
      final Future<void> rosterInit = _loadRosterEmbeddings();

      // Best-effort: creating the session document can fail offline.
      final Future<void> sessionDocInit = _ensureSessionDocumentBestEffort();

      setState(() {
        _statusMessage = 'Opening camera...';
      });

      if (kIsWeb) {
        await _initializeWebCamera();
      } else {
        await _initializeDeviceCamera();
      }

      if (!mounted) return;
      setState(() {
        _initializing = false;
        _statusMessage = 'Camera ready. Loading recognition...';
      });

      // Continue the remaining initialization steps.
      await Future.wait(<Future<void>>[modelInit, rosterInit, sessionDocInit]);

      if (!mounted) return;
      setState(() {
        _statusMessage =
            'Session live. Keep students centered for best recognition results.';
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
    final DocumentReference<Map<String, dynamic>> doc = _firestore
        .collection('attendanceSessions')
        .doc();
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

  Future<void> _ensureSessionDocumentBestEffort() async {
    try {
      // Time-box this so offline sessions don't hang camera startup.
      await _ensureSessionDocument().timeout(const Duration(seconds: 3));
    } catch (_) {
      // Offline or slow network: skip for now.
    }
  }

  Future<void> _loadRosterEmbeddings() async {
    Query<Map<String, dynamic>> query = _firestore
        .collection('users')
        .where('role', isEqualTo: 'student');

    final String sectionLabel = (widget.config.section ?? '').trim();
    if (sectionLabel.isNotEmpty) {
      query = query.where('section', isEqualTo: sectionLabel);
    }

    QuerySnapshot<Map<String, dynamic>> snapshot;
    try {
      snapshot = await query
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 3));
    } catch (_) {
      snapshot = await query
          .get(const GetOptions(source: Source.cache))
          .timeout(const Duration(seconds: 3));
    }
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
      (CameraDescription description) =>
          description.lensDirection == CameraLensDirection.front,
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
    try {
      final InputImage inputImage = _buildInputImage(image);
      final List<Face> faces = await detector.processImage(inputImage);
      if (faces.isEmpty) {
        _updateStatus('No face detected. Ask the student to step closer.');
      } else {
        final Rect bbox = _mapMlKitBboxToRaw(
          faces.first.boundingBox,
          rotationCompensation: _lastRotationCompensation,
          rawWidth: image.width.toDouble(),
          rawHeight: image.height.toDouble(),
        );
        final List<double> embedding = await _embeddingService
            .generateEmbedding(image, bbox);
        _lastCaptureTime = _now();
        await _handleEmbeddingCapture(embedding);
      }
    } catch (error) {
      debugPrint('Camera frame processing error: $error');
    } finally {
      _isProcessingFrame = false;
    }
  }

  Future<void> _processWebFrame() async {
    if (!kIsWeb ||
        !_captureEnabled ||
        _isProcessingFrame ||
        !_embeddingService.isReady) {
      return;
    }
    if (_isWithinCooldown()) {
      return;
    }
    _isProcessingFrame = true;
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
      _lastCaptureTime = _now();
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
    return _now().difference(last) < _captureCooldown;
  }

  Future<void> _handleEmbeddingCapture(List<double> embedding) async {
    final _MatchResult result = _matchEmbedding(embedding);
    final DateTime captureTime = _now();

    if (result.student == null) {
      final DateTime? last = _lastUnrecognizedTime;
      if (last != null &&
          captureTime.difference(last) < _unrecognizedCooldown) {
        return;
      }
      _lastUnrecognizedTime = captureTime;
      final double? best = result.similarity;
      final double? second = result.secondBestSimilarity;
      if (best == null || best.isNaN) {
        _updateStatus('Face detected but no match found in roster.');
      } else {
        final String hint = best < 0.30
            ? ' Re-enroll this student in the Android app.'
            : '';
        if (second != null && !second.isNaN) {
          final double margin = best - second;
          final String reason =
              result.rejectionReason == 'ambiguous' ? ' Ambiguous match.' : '';
          _updateStatus(
            'Face detected but no match found in roster.$reason '
            '(top1 ${best.toStringAsFixed(2)}, top2 ${second.toStringAsFixed(2)}, '
            'margin ${margin.toStringAsFixed(2)}, '
            'threshold ${_similarityThreshold.toStringAsFixed(2)}, '
            'min margin ${_similarityMargin.toStringAsFixed(2)})$hint',
          );
        } else {
          _updateStatus(
            'Face detected but no match found in roster. '
            '(best similarity ${best.toStringAsFixed(2)}, '
            'threshold ${_similarityThreshold.toStringAsFixed(2)})$hint',
          );
        }
      }
      return;
    }

    if (result.student != null) {
      final String studentId = result.student!.userId;

      // Only recognize/persist a student once per session to avoid spam.
      if (_capturedStudentIds.contains(studentId)) {
        return;
      }

      if (_shouldThrottleStudentCapture(studentId, captureTime)) {
        return;
      }

      _recordLocalCapture(result, captureTime);
      _capturedStudentIds.add(studentId);
      try {
        await _persistCapture(result, embedding, captureTime);
      } catch (_) {
        // If persistence fails, allow re-capture.
        _capturedStudentIds.remove(studentId);
        rethrow;
      }
      return;
    }
  }

  _MatchResult _matchEmbedding(List<double> embedding) {
    if (_roster.isEmpty) {
      return _MatchResult(embedding: embedding);
    }

    final List<double> probe = _l2NormalizeVector(embedding);
    if (probe.isEmpty) {
      return _MatchResult(embedding: embedding, similarity: -1);
    }

    _RecognizedStudent? bestCandidate;
    double bestSimilarity = -1;
    double secondBestSimilarity = -1;

    // Compare on a per-student basis: each student contributes their best
    // similarity across their stored embeddings.
    for (final _RecognizedStudent student in _roster) {
      double bestForStudent = -1;
      for (final List<double> candidate in student.embeddings) {
        final double similarity = _cosineSimilarityNormalized(probe, candidate);
        if (similarity > bestForStudent) {
          bestForStudent = similarity;
        }
      }

      if (bestForStudent > bestSimilarity) {
        secondBestSimilarity = bestSimilarity;
        bestSimilarity = bestForStudent;
        bestCandidate = student;
      } else if (bestForStudent > secondBestSimilarity) {
        secondBestSimilarity = bestForStudent;
      }
    }

    if (bestCandidate == null) {
      return _MatchResult(embedding: embedding);
    }

    if (bestSimilarity < _similarityThreshold) {
      return _MatchResult(
        embedding: embedding,
        similarity: bestSimilarity,
        secondBestSimilarity: secondBestSimilarity,
        rejectionReason: 'below-threshold',
      );
    }

    final double margin = bestSimilarity - secondBestSimilarity;
    if (secondBestSimilarity >= 0 && margin < _similarityMargin) {
      return _MatchResult(
        embedding: embedding,
        similarity: bestSimilarity,
        secondBestSimilarity: secondBestSimilarity,
        rejectionReason: 'ambiguous',
      );
    }

    final double confidence = _similarityToDisplayConfidence(bestSimilarity);
    return _MatchResult(
      embedding: embedding,
      student: bestCandidate,
      similarity: bestSimilarity,
      secondBestSimilarity: secondBestSimilarity,
      confidence: confidence,
    );
  }

  void _recordLocalCapture(_MatchResult result, DateTime captureTime) {
    if (result.student == null) {
      return;
    }
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
      _statusMessage =
          'Recognized ${result.student!.displayName} '
          '(${_formatConfidence(result.confidence!)})';
    });
  }

  Future<void> _persistCapture(
    _MatchResult result,
    List<double> embedding,
    DateTime captureTime,
  ) async {
    final String? sessionId = _sessionDocId;
    if (sessionId == null) {
      return;
    }
    final String? attendanceStatus = result.student == null
        ? null
        : _classifyAttendanceStatus(captureTime);
    final DocumentReference<Map<String, dynamic>> sessionRef = _firestore
        .collection('attendanceSessions')
        .doc(sessionId);
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
      await sessionRef
          .collection('attendees')
          .doc(result.student!.userId)
          .set(<String, dynamic>{
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
    return DateTime(
      reference.year,
      reference.month,
      reference.day,
      time.hour,
      time.minute,
    );
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
      (_RecognizedStudent student) =>
          !countedStudentIds.contains(student.userId),
    );
    for (final _RecognizedStudent student in uncaptured) {
      await _updateClassAttendanceStats(
        studentId: student.userId,
        newStatus: 'absent',
      );
    }
  }

  InputImage _buildInputImage(CameraImage image) {
    final CameraController? controller = _cameraController;

    final Size imageSize = Size(
      image.width.toDouble(),
      image.height.toDouble(),
    );

    int deviceRotationDegrees = 0;
    if (controller != null) {
      deviceRotationDegrees = switch (controller.value.deviceOrientation) {
        DeviceOrientation.portraitUp => 0,
        DeviceOrientation.landscapeLeft => 90,
        DeviceOrientation.portraitDown => 180,
        DeviceOrientation.landscapeRight => 270,
      };
    }

    final int sensorOrientation =
        controller?.description.sensorOrientation ?? 0;
    final bool isFront =
        controller?.description.lensDirection == CameraLensDirection.front;

    final int rotationCompensation = isFront
        ? (sensorOrientation + deviceRotationDegrees) % 360
        : (sensorOrientation - deviceRotationDegrees + 360) % 360;

    // Persist for embedding bbox mapping.
    _lastRotationCompensation = rotationCompensation;

    final InputImageRotation rotation =
        InputImageRotationValue.fromRawValue(rotationCompensation) ??
        InputImageRotation.rotation0deg;

    // On Android the camera plugin provides YUV_420_888 (3 planes).
    // MLKit is reliable with NV21 bytes + nv21 metadata.
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      final Uint8List nv21 = _yuv420ToNv21(image);
      final InputImageMetadata metadata = InputImageMetadata(
        size: imageSize,
        rotation: rotation,
        format: InputImageFormat.nv21,
        bytesPerRow: image.width,
      );
      return InputImage.fromBytes(bytes: nv21, metadata: metadata);
    }

    // Fallback for other platforms.
    final InputImageFormat format =
        InputImageFormatValue.fromRawValue(image.format.raw) ??
        InputImageFormat.nv21;

    final Uint8List bytes;
    if (image.planes.length == 1) {
      bytes = image.planes.first.bytes;
    } else {
      final WriteBuffer allBytes = WriteBuffer();
      for (final Plane plane in image.planes) {
        allBytes.putUint8List(plane.bytes);
      }
      bytes = allBytes.done().buffer.asUint8List();
    }

    final InputImageMetadata metadata = InputImageMetadata(
      size: imageSize,
      rotation: rotation,
      format: format,
      bytesPerRow: image.planes.first.bytesPerRow,
    );
    return InputImage.fromBytes(bytes: bytes, metadata: metadata);
  }

  Rect _mapMlKitBboxToRaw(
    Rect bbox, {
    required int rotationCompensation,
    required double rawWidth,
    required double rawHeight,
  }) {
    if (rawWidth <= 0 || rawHeight <= 0) return bbox;

    Rect mapped;
    switch (rotationCompensation % 360) {
      case 90:
        mapped = Rect.fromLTRB(
          rawWidth - bbox.bottom,
          bbox.left,
          rawWidth - bbox.top,
          bbox.right,
        );
        break;
      case 180:
        mapped = Rect.fromLTRB(
          rawWidth - bbox.right,
          rawHeight - bbox.bottom,
          rawWidth - bbox.left,
          rawHeight - bbox.top,
        );
        break;
      case 270:
        mapped = Rect.fromLTRB(
          bbox.top,
          rawHeight - bbox.right,
          bbox.bottom,
          rawHeight - bbox.left,
        );
        break;
      case 0:
      default:
        mapped = bbox;
        break;
    }

    // Clamp into the raw buffer bounds.
    final double left = mapped.left.clamp(0.0, rawWidth);
    final double top = mapped.top.clamp(0.0, rawHeight);
    final double right = mapped.right.clamp(0.0, rawWidth);
    final double bottom = mapped.bottom.clamp(0.0, rawHeight);
    return Rect.fromLTRB(
      math.min(left, right),
      math.min(top, bottom),
      math.max(left, right),
      math.max(top, bottom),
    );
  }

  Uint8List _yuv420ToNv21(CameraImage image) {
    final int width = image.width;
    final int height = image.height;
    final int ySize = width * height;
    final int uvSize = ySize ~/ 4;
    final Uint8List nv21 = Uint8List(ySize + uvSize * 2);

    final Plane yPlane = image.planes[0];
    final Plane uPlane = image.planes[1];
    final Plane vPlane = image.planes[2];

    // Copy Y plane (accounting for row stride).
    int outIndex = 0;
    for (int row = 0; row < height; row++) {
      final int rowStart = row * yPlane.bytesPerRow;
      nv21.setRange(outIndex, outIndex + width, yPlane.bytes, rowStart);
      outIndex += width;
    }

    final int uvHeight = height ~/ 2;
    final int uvWidth = width ~/ 2;
    final int uRowStride = uPlane.bytesPerRow;
    final int vRowStride = vPlane.bytesPerRow;
    final int uPixelStride = uPlane.bytesPerPixel ?? 1;
    final int vPixelStride = vPlane.bytesPerPixel ?? 1;

    for (int row = 0; row < uvHeight; row++) {
      final int uRow = row * uRowStride;
      final int vRow = row * vRowStride;
      for (int col = 0; col < uvWidth; col++) {
        final int uIndex = uRow + col * uPixelStride;
        final int vIndex = vRow + col * vPixelStride;
        // NV21 stores V then U.
        nv21[outIndex++] = vPlane.bytes[vIndex];
        nv21[outIndex++] = uPlane.bytes[uIndex];
      }
    }

    return nv21;
  }

  double _cosineSimilarityNormalized(List<double> aUnit, List<double> bUnit) {
    final int length = math.min(aUnit.length, bUnit.length);
    if (length <= 0) return -1;
    double dot = 0;
    for (int i = 0; i < length; i++) {
      dot += aUnit[i] * bUnit[i];
    }
    // Avoid tiny numeric drift.
    return dot.clamp(-1.0, 1.0);
  }

  double _similarityToDisplayConfidence(double similarity) {
    // Display mapping (not a calibrated probability): below threshold maps to
    // 0–84%, and above threshold maps to 85–100%.
    if (similarity.isNaN || similarity <= 0) {
      return 0;
    }

    if (similarity < _similarityThreshold) {
      final double ratio = similarity / _similarityThreshold;
      return (ratio * 0.84).clamp(0.0, 0.84);
    }

    final double delta = similarity - _similarityThreshold;
    final double t = (delta / _confidenceSpan).clamp(0.0, 1.0);
    return (0.85 + (t * 0.15)).clamp(0.0, 1.0);
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
      await _firestore.collection('attendanceSessions').doc(sessionId).update(
        <String, dynamic>{
          'status': 'completed',
          'endedAt': FieldValue.serverTimestamp(),
        },
      );
    } catch (_) {
      // Best-effort update only.
    } finally {
      await _markUncapturedStudentsAbsent();
      _sessionClosed = true;
    }
  }

  void _updateStatus(String message) {
    if (!mounted) return;
    if (_statusMessage == message) {
      return;
    }
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
                      margin: const EdgeInsets.fromLTRB(8, 8, 8, 4),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(24),
                        color: theme.colorScheme.surfaceContainerHighest,
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: preview,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Text(
                          _statusMessage ?? 'Initializing session... hold on.',
                          style: theme.textTheme.bodyMedium,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 8),
                        FilledButton.icon(
                          onPressed: _initializing ? null : _toggleCapture,
                          icon: Icon(
                            _captureEnabled
                                ? Icons.pause_circle
                                : Icons.play_circle,
                          ),
                          label: Text(
                            _captureEnabled
                                ? 'Pause recognition'
                                : 'Resume recognition',
                          ),
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
                  Text(
                    '${config.subjectCode} • ${config.subjectName}',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(_formatSection(config)),
                  const SizedBox(height: 8),
                  Text(
                    _formatSchedule(context, config),
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            Column(
              children: <Widget>[
                const Text('Roster embeddings'),
                Text(
                  rosterCount.toString(),
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _formatSection(AttendanceSessionConfig config) {
    final String sectionLabel = config.section == null
        ? 'Section TBD'
        : 'Section ${config.section}';
    final String termLabel = config.term == null ? '' : ' • ${config.term}';
    final String locationLabel = config.location == null
        ? ''
        : ' • ${config.location}';
    return '$sectionLabel$termLabel$locationLabel';
  }

  static String _formatSchedule(
    BuildContext context,
    AttendanceSessionConfig config,
  ) {
    final MaterialLocalizations localizations = MaterialLocalizations.of(
      context,
    );
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
  const _RecentCapturesList({required this.captures, required this.controller});

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
          SizedBox(
            height: 160,
            child: captures.isEmpty
                ? const Center(
                    child: Text(
                      'No captures yet. Position a student in front of the camera to begin.',
                      textAlign: TextAlign.center,
                    ),
                  )
                : Scrollbar(
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
                            capture.matchDisplayName == null
                                ? Icons.help_outline
                                : Icons.verified_user_outlined,
                          ),
                          title: Text(
                            capture.matchDisplayName ?? 'Unrecognized face',
                          ),
                          subtitle: Text(
                            'Captured at ${TimeOfDay.fromDateTime(capture.timestamp).format(context)}',
                          ),
                          trailing: capture.confidence == null
                              ? const Text('No match')
                              : Text(
                                  '${(capture.confidence! * 100).toStringAsFixed(1)}%',
                                ),
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
    required this.embeddings,
  });

  final String userId;
  final String displayName;
  final List<List<double>> embeddings;

  static _RecognizedStudent? fromDocument(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final Map<String, dynamic> data = doc.data();
    final String? provider = data['faceEmbedProvider'] as String?;
    if (!kIsWeb && provider == 'web_fallback') {
      return null;
    }
    final List<List<double>> embeddings = _readEmbeddings(data);
    if (embeddings.isEmpty) {
      return null;
    }
    final String displayName = _resolveDisplayName(data, doc.id);
    return _RecognizedStudent(
      userId: doc.id,
      displayName: displayName,
      embeddings: embeddings,
    );
  }

  static List<List<double>> _readEmbeddings(Map<String, dynamic> data) {
    final dynamic rawMulti = data['faceEmbeds'];
    if (rawMulti is List && rawMulti.isNotEmpty) {
      final List<List<double>> parsed = <List<double>>[];
      for (final dynamic item in rawMulti) {
        List<num>? rawVec;
        if (item is List) {
          rawVec = item.whereType<num>().toList(growable: false);
        } else if (item is Map) {
          final dynamic v = item['v'];
          if (v is List) {
            rawVec = v.whereType<num>().toList(growable: false);
          }
        }
        if (rawVec == null || rawVec.isEmpty) continue;

        final List<double> vec = rawVec
            .map((num v) => v.toDouble())
            .toList(growable: false);
        final List<double> normalized = _l2NormalizeVector(vec);
        if (normalized.isNotEmpty) {
          parsed.add(normalized);
        }
      }
      if (parsed.isNotEmpty) {
        return parsed;
      }
    }

    final List<dynamic>? rawSingle = data['faceEmbed'] as List<dynamic>?;
    if (rawSingle == null || rawSingle.isEmpty) {
      return <List<double>>[];
    }
    final List<double> embedding = rawSingle
      .map((dynamic value) => (value as num).toDouble())
      .toList(growable: false);
    final List<double> normalized = _l2NormalizeVector(embedding);
    return normalized.isEmpty ? <List<double>>[] : <List<double>>[normalized];
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
    this.secondBestSimilarity,
    this.confidence,
    this.rejectionReason,
  });

  final List<double> embedding;
  final _RecognizedStudent? student;
  final double? similarity;
  final double? secondBestSimilarity;
  final double? confidence;
  final String? rejectionReason;
}
