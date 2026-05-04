import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import 'services/face_embedding_service.dart';
import 'services/face_quality_exception.dart';
import 'services/attendance_outbox_service.dart';
import 'services/roster_cache_locator.dart';
import 'services/roster_embeddings_cache.dart';
import 'services/vps_embeddings_api_client.dart';
import 'widgets/clay_surface.dart';

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

List<double> _averageVectors(List<List<double>> vectors) {
  if (vectors.isEmpty) return <double>[];
  final int length = vectors.first.length;
  if (length <= 0) return <double>[];
  final List<double> sums = List<double>.filled(length, 0);
  for (final List<double> v in vectors) {
    if (v.length != length) continue;
    for (int i = 0; i < length; i++) {
      sums[i] += v[i];
    }
  }
  final double divisor = vectors.length.toDouble();
  if (divisor <= 0) return <double>[];
  return sums.map((double value) => value / divisor).toList(growable: false);
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
    this.scheduleType,
    this.location,
    this.resumeSessionId,
  });

  final String classId;
  final String subjectCode;
  final String subjectName;
  final String? section;
  final String? term;
  final String? scheduleType;
  final String? location;
  final int dayOfWeek;
  final TimeOfDay start;
  final TimeOfDay end;
  final String? resumeSessionId;

  String get scheduleKey {
    String two(int n) => n.toString().padLeft(2, '0');
    final String startKey = '${two(start.hour)}${two(start.minute)}';
    final String endKey = '${two(end.hour)}${two(end.minute)}';
    return 'd$dayOfWeek-${startKey}_$endKey';
  }
}

class AttendanceSessionPage extends StatefulWidget {
  const AttendanceSessionPage({super.key, required this.config});

  static const String routeName = '/attendance-session';

  final AttendanceSessionConfig config;

  @override
  State<AttendanceSessionPage> createState() => _AttendanceSessionPageState();
}

enum _AttendanceSessionViewMode { roster, verify }

class _AttendanceSessionPageState extends State<AttendanceSessionPage>
  with WidgetsBindingObserver {
  // Recognition is strictly gated to minimize false positives.
  // Tune these with real class data if needed.
  static const double _similarityThreshold = 0.67;
  static const double _singleTemplateThreshold = 0.75;
  static const double _templateHitThreshold = 0.66;
  static const int _minTemplateHits = 2;
  // 1:1 verification (selected student) can be slightly more forgiving than
  // roster-wide matching without materially increasing false positives.
  // This primarily reduces false negatives for students with only 1 template.
  static const double _verifySingleTemplateThreshold = 0.72;
  static const int _verifyMinTemplateHits = 1;
  static const double _similarityMargin = 0.14;
  static const double _confidenceSpan = 0.20;
  static const Duration _captureCooldown = Duration(seconds: 1);
  static const Duration _confirmingCaptureCooldown = Duration(
    milliseconds: 300,
  );
  static const Duration _duplicateCaptureCooldown = Duration(seconds: 10);
  static const Duration _unrecognizedCooldown = Duration(milliseconds: 1200);
  static const Duration _unalignedFallbackCooldown = Duration(seconds: 2);
  static const Duration _ambiguousConfirmationWindow = Duration(seconds: 7);
  static const int _ambiguousConfirmationsRequired = 4;
  static const Duration _confirmationWindow = Duration(seconds: 6);
  static const int _confirmationsRequired = 3;
  static const Duration _maxConfirmationDuration = Duration(seconds: 12);

  // Never record an attendance entry off an ambiguous (top1≈top2) result.
  // Ambiguity is the most common source of false positives when the student is
  // far away or moving/tilting.
  static const Duration _decisionStatusUpdateMinInterval = Duration(
    milliseconds: 900,
  );

  // Legacy-compat matching:
  // If the normal embedding conversion can't match confidently (common when
  // roster templates were enrolled using the older YUV UV-stride bug), we try a
  // second embedding using the legacy conversion and only accept if it's
  // clearly better and does not disagree with the normal mode.
  static const double _legacyOverrideMinSimilarity = 0.75;
  static const double _legacyOverrideMinMargin = 0.16;

  // Temporal smoothing: average a few recent unit embeddings to reduce
  // per-frame noise and help separate close candidates.
  static const int _probeSmoothingWindow = 3;
  static const Duration _probeSmoothingResetAfter = Duration(
    milliseconds: 1500,
  );

  // Throttle camera frame processing to avoid UI jank.
  static const Duration _frameProcessingInterval = Duration(milliseconds: 480);
  static const Duration _confirmingFrameProcessingInterval = Duration(
    milliseconds: 320,
  );

  // Rate-limit status updates to avoid rebuilding the entire page too often
  // while the camera stream is running.
  static const Duration _statusUpdateMinInterval = Duration(milliseconds: 350);

  // Distance tuning.
  // We estimate distance by how large the face bbox is relative to the frame.
  // Smaller ratio => farther away => lower-detail crops => more "no match".
  //
  // Policy:
  // - Too far: skip embedding/matching, ask user to move closer.
  // - Mid-distance: use stricter matching to avoid false positives.
  static const double _distanceTooFarRatio = 0.22;
  static const double _distanceSweetMaxRatio = 0.30;
  static const double _sweetSimilarityThreshold = 0.71;
  static const double _sweetSingleTemplateThreshold = 0.79;
  static const int _sweetMinTemplateHits = 2;

  static const double _verifySweetSingleTemplateThreshold = 0.75;
  static const int _verifySweetMinTemplateHits = 1;

  static const int _centroidPrefilterTopK = 12;

  final FaceEmbeddingService _embeddingService = FaceEmbeddingService.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  CameraController? _cameraController;
  FaceDetector? _faceDetector;
  Timer? _sessionUiTimer;
  Timer? _autoEndTimer;

  bool _isProcessingFrame = false;
  bool _captureEnabled = true;
  bool _isEndingSession = false;
  bool _initializing = true;
  String? _statusMessage;
  bool _attemptedInstructorClaimBootstrap = false;
  DateTime? _lastFrameProcessedAt;
  DateTime? _lastStatusUpdatedAt;
  String? _sessionDocId;
  bool _sessionClosed = false;
  DateTime? _sessionStartedAt;
  DateTime? _scheduledEndAt;
  String? _sessionPointerDateKey;
  DateTime? _lastCaptureTime;
  DateTime? _lastUnrecognizedTime;
  DateTime? _lastUnalignedFallbackAt;
  DateTime? _lastProbeSampleAt;
  int _lastRotationCompensation = 0;
  int _clientCaptureSeq = 0;

  final List<List<double>> _probeHistoryUnit = <List<double>>[];

  static const String _kSessionPointerCollection = 'attendanceSessionPointers';

  bool get _recognitionSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  List<_RecognizedStudent> _roster = <_RecognizedStudent>[];
  final RosterEmbeddingsCache _rosterCache = getRosterEmbeddingsCache();
  DateTime? _rosterCacheUpdatedAtUtc;
  final List<_AttendanceCapture> _recentCaptures = <_AttendanceCapture>[];
  final Map<String, String> _recordedStatuses = <String, String>{};
  final Map<String, int> _recordedLateMinutes = <String, int>{};
  final Map<String, DateTime> _lastStudentCaptureTimes = <String, DateTime>{};
  final Set<String> _capturedStudentIds = <String>{};
  final Set<String> _pendingCapturedStudentIds = <String>{};
  final ScrollController _captureListController = ScrollController();

  _AttendanceSessionViewMode _viewMode = _AttendanceSessionViewMode.roster;
  _RecognizedStudent? _selectedStudent;
  bool _openingCamera = false;

  String? _pendingAmbiguousStudentId;
  int _pendingAmbiguousConfirmations = 0;
  DateTime? _pendingAmbiguousExpiresAt;
  DateTime? _pendingAmbiguousStartedAt;

  String? _pendingStudentId;
  String? _pendingStudentName;
  int _pendingConfirmations = 0;
  DateTime? _pendingExpiresAt;
  DateTime? _pendingStartedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_recognitionSupported) {
      _faceDetector = FaceDetector(
        options: FaceDetectorOptions(
          performanceMode: FaceDetectorMode.fast,
          enableLandmarks: true,
          enableContours: false,
          enableTracking: false,
        ),
      );
    }

    // Refresh the UI periodically so the primary action can automatically
    // switch to "End session now" once the class end time is reached.
    _sessionUiTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!mounted) return;
      _checkAutoEnd();
      setState(() {});
    });

    _initializeSession();
  }

  

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // When the app resumes, attempt to flush any pending outbox ops and
      // refresh session attendees so the UI reflects server-confirmed state.
      unawaited(() async {
        final String? sessionId = _sessionDocId;
        if (sessionId == null || sessionId.trim().isEmpty) return;
        try {
          await AttendanceOutboxService.instance.flushBestEffort();
        } catch (_) {
          // Best-effort only.
        }
        try {
          await _loadRecordedAttendeesBestEffort();
        } catch (_) {}
        try {
          await _applyPendingOutboxOpsToState(sessionId);
        } catch (_) {}
      }());
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _resetProbeAndPendingState() {
    _probeHistoryUnit.clear();
    _lastProbeSampleAt = null;
    _lastUnalignedFallbackAt = null;

    _pendingAmbiguousStudentId = null;
    _pendingAmbiguousConfirmations = 0;
    _pendingAmbiguousExpiresAt = null;
    _pendingAmbiguousStartedAt = null;

    _pendingStudentId = null;
    _pendingStudentName = null;
    _pendingConfirmations = 0;
    _pendingExpiresAt = null;
    _pendingStartedAt = null;
  }

  DateTime _now() {
    return DateTime.now();
  }

  bool _shouldEndSessionNow() {
    final DateTime now = _now();
    final DateTime? scheduledEnd = _scheduledEndAt;
    if (scheduledEnd == null) return false;
    return now.isAfter(scheduledEnd) || now.isAtSameMomentAs(scheduledEnd);
  }

  void _scheduleAutoEndTimer() {
    _autoEndTimer?.cancel();
    _autoEndTimer = null;

    final DateTime? scheduledEnd = _scheduledEndAt;
    if (scheduledEnd == null) {
      return;
    }

    final Duration remaining = scheduledEnd.difference(_now());
    if (remaining <= Duration.zero) {
      _checkAutoEnd();
      return;
    }

    _autoEndTimer = Timer(remaining, () {
      if (!mounted) return;
      _checkAutoEnd();
    });
  }

  void _checkAutoEnd() {
    if (_sessionClosed) return;
    if (_initializing) return;
    if (_isEndingSession) return;
    if (!_shouldEndSessionNow()) return;

    // Best-effort: end the session at the scheduled end time.
    // This may run slightly late if the app is backgrounded.
    unawaited(_endSession());
  }

  Future<void> _setSessionStatusBestEffort(String status) async {
    final String? sessionId = _sessionDocId;
    if (sessionId == null || _sessionClosed) return;

    final String timestampField = switch (status) {
      'paused' => 'pausedAt',
      'active' => 'resumedAt',
      _ => 'statusUpdatedAt',
    };

    try {
      await _firestore.collection('attendanceSessions').doc(sessionId).update(
        <String, dynamic>{
          'status': status,
          timestampField: FieldValue.serverTimestamp(),
        },
      );
    } catch (_) {
      // Best-effort update only.
    }
  }

  Future<void> _initializeSession() async {
    _sessionStartedAt ??= _now();
    _scheduledEndAt ??= _computeScheduledEnd(_sessionStartedAt!);
    _scheduleAutoEndTimer();
    setState(() {
      _initializing = true;
      _statusMessage = 'Loading roster...';
    });

    try {
      // Start long-running initialization tasks early, but do not block
      // opening the camera preview on them. This improves perceived
      // performance (especially when offline and Firestore server calls hang).
      final Future<void> modelInit = _embeddingService.initialize();
      final Future<void> rosterInit = _loadRosterEmbeddings();

      // Best-effort: creating the session document can fail offline.
      final Future<void> sessionDocInit = _ensureSessionDocumentBestEffort();
      final Future<void> attendeesInit = sessionDocInit.then((_) {
        return _loadRecordedAttendeesBestEffort();
      });

      if (!_recognitionSupported) {
        // uses a lightweight fallback embedding (no MLKit face detection / ONNX).
        // Make this explicit to avoid misleading results.
        if (!mounted) return;
        setState(() {
          _initializing = false;
          _captureEnabled = false;
          _statusMessage =
              'Attendance face scanning is available only in the Android app.';
        });

        // Still complete best-effort initialization so the session can be
        // created/ended cleanly and roster count can load.
        await Future.wait(<Future<void>>[
          modelInit,
          rosterInit,
          sessionDocInit,
          attendeesInit,
        ]);
        return;
      }

      // Camera is initialized lazily after the instructor selects a student.
      await Future.wait(<Future<void>>[
        rosterInit,
        sessionDocInit,
        attendeesInit,
      ]);
      if (!mounted) return;
      setState(() {
        _initializing = false;
        _statusMessage = _embeddingService.isReady
            ? 'Select a student from the roster to begin face verification.'
            : 'Loading recognition model... You can browse the roster while it loads.';
      });

      unawaited(() async {
        try {
          await modelInit;
        } catch (_) {
          // Best-effort only.
        }
        if (!mounted) return;
        if (_viewMode != _AttendanceSessionViewMode.roster) return;
        if (_initializing) return;
        setState(() {
          _statusMessage =
              'Select a student from the roster to begin face verification.';
        });
      }());
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

    // Anchor the pointer ID to the date at session launch (deterministic across retries).
    _sessionPointerDateKey ??= _dateKey(_now());

    final User? user = FirebaseAuth.instance.currentUser;
    final String? uid = user?.uid;
    if (uid == null || uid.isEmpty) {
      throw StateError('Not signed in.');
    }

    final DateTime now = _now();
    _sessionPointerDateKey ??= _dateKey(now);

    final String dateKey = _sessionPointerDateKey ?? _dateKey(now);
    final String canonicalSessionId = _buildCanonicalSessionId(
      instructorId: uid,
      classId: widget.config.classId,
      dateKey: dateKey,
      scheduleKey: widget.config.scheduleKey,
    );

    final DateTime scheduledStart = _dateWithTime(now, widget.config.start);
    DateTime scheduledEnd = _dateWithTime(now, widget.config.end);
    if (scheduledEnd.isBefore(scheduledStart)) {
      scheduledEnd = scheduledEnd.add(const Duration(days: 1));
    }
    _scheduledEndAt = scheduledEnd;

    final DocumentReference<Map<String, dynamic>> canonicalRef = _firestore
        .collection('attendanceSessions')
        .doc(canonicalSessionId);

    // 1) Prefer the canonical document if it already exists.
    // This prevents duplicate "attempt" sessions for the same day+schedule.
    try {
      DocumentSnapshot<Map<String, dynamic>> snap;
      try {
        snap = await canonicalRef
            .get(const GetOptions(source: Source.server))
            .timeout(const Duration(seconds: 3));
      } catch (_) {
        snap = await canonicalRef
            .get(const GetOptions(source: Source.cache))
            .timeout(const Duration(seconds: 2));
      }

      if (snap.exists) {
        _sessionDocId = canonicalSessionId;
        final Map<String, dynamic>? data = snap.data();
        _applySessionMetaFromDoc(data);

        // Safety: never implicitly re-activate completed sessions.
        // Re-opening a completed session is an explicit user action.
        final String docStatus =
            (data?['status'] as String?)?.trim().toLowerCase() ?? '';
        final bool hasEndedAt = data != null && data['endedAt'] is Timestamp;
        if (docStatus == 'completed' || hasEndedAt) {
          _sessionDocId = null;
          throw StateError('Refusing to resume a completed session.');
        }

        await canonicalRef.set(<String, dynamic>{
          'status': 'active',
          'resumedAt': FieldValue.serverTimestamp(),
          'scheduleKey': widget.config.scheduleKey,
          'dateKey': dateKey,
          'dayOfWeek': widget.config.dayOfWeek,
          'startHour': widget.config.start.hour,
          'startMinute': widget.config.start.minute,
          'endHour': widget.config.end.hour,
          'endMinute': widget.config.end.minute,
          'scheduledStartAt': Timestamp.fromDate(scheduledStart),
          'scheduledEndAt': Timestamp.fromDate(scheduledEnd),
        }, SetOptions(merge: true));
        await _upsertSessionPointer(status: 'active');

        // Best-effort: collapse any historical duplicates into the canonical doc.
        await _mergeDuplicateSessionAttemptsBestEffort(
          canonicalSessionId: canonicalSessionId,
          scheduledStart: scheduledStart,
        );
        return;
      }
    } catch (_) {
      // Ignore and continue to migration/creation.
    }

    // 2) If a resume session exists (legacy random ID), migrate it into the
    // canonical doc so "Start session" never creates a second attempt.
    final String? resumeId = widget.config.resumeSessionId;
    final String? normalizedResume =
        (resumeId != null && resumeId.trim().isNotEmpty)
        ? resumeId.trim()
        : null;

    if (normalizedResume != null && normalizedResume != canonicalSessionId) {
      final DocumentReference<Map<String, dynamic>> resumeRef = _firestore
          .collection('attendanceSessions')
          .doc(normalizedResume);
      try {
        DocumentSnapshot<Map<String, dynamic>> snap;
        try {
          snap = await resumeRef
              .get(const GetOptions(source: Source.server))
              .timeout(const Duration(seconds: 3));
        } catch (_) {
          snap = await resumeRef
              .get(const GetOptions(source: Source.cache))
              .timeout(const Duration(seconds: 2));
        }
        if (snap.exists) {
          final Map<String, dynamic>? data = snap.data();

          // Safety: never implicitly re-activate completed sessions.
          final String docStatus =
              (data?['status'] as String?)?.trim().toLowerCase() ?? '';
          final bool hasEndedAt = data != null && data['endedAt'] is Timestamp;
          if (docStatus == 'completed' || hasEndedAt) {
            throw StateError('Refusing to resume a completed session.');
          }

          // Copy the session metadata into the canonical doc (best-effort).
          final Map<String, dynamic> copy = <String, dynamic>{
            ...?data,
            'status': 'active',
            'resumedAt': FieldValue.serverTimestamp(),
            'scheduleKey': widget.config.scheduleKey,
            'dateKey': dateKey,
            'dayOfWeek': widget.config.dayOfWeek,
            'startHour': widget.config.start.hour,
            'startMinute': widget.config.start.minute,
            'endHour': widget.config.end.hour,
            'endMinute': widget.config.end.minute,
            'scheduledStartAt': Timestamp.fromDate(scheduledStart),
            'scheduledEndAt': Timestamp.fromDate(scheduledEnd),
          };

          await canonicalRef.set(copy, SetOptions(merge: true));
        }
      } catch (_) {
        // Ignore.
      }
    }

    // 3) Create/reuse the canonical session doc.
    await canonicalRef.set(<String, dynamic>{
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
      'scheduleKey': widget.config.scheduleKey,
      'dateKey': dateKey,
      'scheduledStartAt': Timestamp.fromDate(scheduledStart),
      'scheduledEndAt': Timestamp.fromDate(scheduledEnd),
      'instructorId': uid,
      'instructorEmail': user?.email,
      'status': 'active',
      'startedAt': FieldValue.serverTimestamp(),
      'createdAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    _sessionDocId = canonicalSessionId;

    await _upsertSessionPointer(status: 'active');

    await _mergeDuplicateSessionAttemptsBestEffort(
      canonicalSessionId: canonicalSessionId,
      scheduledStart: scheduledStart,
    );

    // Anchor the session start time on Firestore server time.
    // This avoids device clock drift affecting the 30-minute cutoff.
    try {
      final DocumentSnapshot<Map<String, dynamic>> snap = await canonicalRef
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 2));
      final Object? startedAt = snap.data() != null
          ? snap.data()!['startedAt']
          : null;
      if (startedAt is Timestamp) {
        _sessionStartedAt = startedAt.toDate();
      }
    } catch (_) {
      // Offline/slow network: keep the local start time fallback.
    }
  }

  String _buildCanonicalSessionId({
    required String instructorId,
    required String classId,
    required String dateKey,
    required String scheduleKey,
  }) {
    String sanitize(String input) {
      final String trimmed = input.trim();
      return trimmed
          .replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_')
          .replaceAll(RegExp(r'_+'), '_');
    }

    final String a = sanitize(instructorId);
    final String b = sanitize(classId);
    final String c = sanitize(dateKey);
    final String d = sanitize(scheduleKey);
    return 'sess_${a}_${b}_${c}_$d';
  }

  void _applySessionMetaFromDoc(Map<String, dynamic>? data) {
    if (data == null) return;

    final Timestamp? scheduledEndTs = data['scheduledEndAt'] as Timestamp?;
    if (scheduledEndTs != null) {
      _scheduledEndAt = scheduledEndTs.toDate();
    }

    final Object? startedAt = data['startedAt'];
    final Timestamp? started = startedAt is Timestamp ? startedAt : null;
    if (started != null) {
      _sessionStartedAt = started.toDate();
      _scheduledEndAt ??= _computeScheduledEnd(_sessionStartedAt!);
    }

    _scheduleAutoEndTimer();
  }

  Future<void> _mergeDuplicateSessionAttemptsBestEffort({
    required String canonicalSessionId,
    required DateTime scheduledStart,
  }) async {
    final String? uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || uid.isEmpty) return;
    if (_sessionDocId == null || _sessionDocId != canonicalSessionId) {
      return;
    }

    QuerySnapshot<Map<String, dynamic>> snap;
    try {
      snap = await _firestore
          .collection('attendanceSessions')
          .where('instructorId', isEqualTo: uid)
          .where('classId', isEqualTo: widget.config.classId)
          .where(
            'scheduledStartAt',
            isEqualTo: Timestamp.fromDate(scheduledStart),
          )
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 4));
    } catch (_) {
      try {
        snap = await _firestore
            .collection('attendanceSessions')
            .where('instructorId', isEqualTo: uid)
            .where('classId', isEqualTo: widget.config.classId)
            .where(
              'scheduledStartAt',
              isEqualTo: Timestamp.fromDate(scheduledStart),
            )
            .get(const GetOptions(source: Source.cache))
            .timeout(const Duration(seconds: 2));
      } catch (_) {
        return;
      }
    }

    final List<QueryDocumentSnapshot<Map<String, dynamic>>> docs = snap.docs;
    if (docs.length <= 1) return;

    final Set<String> sessionIds = docs
        .map((QueryDocumentSnapshot<Map<String, dynamic>> d) => d.id)
        .where((String id) => id.trim().isNotEmpty)
        .toSet();
    if (sessionIds.length <= 1) return;

    // Merge attendees locally first (works offline if cached).
    final DocumentReference<Map<String, dynamic>> canonicalRef = _firestore
        .collection('attendanceSessions')
        .doc(canonicalSessionId);

    for (final String id in sessionIds) {
      if (id == canonicalSessionId) continue;
      final CollectionReference<Map<String, dynamic>> attendees = _firestore
          .collection('attendanceSessions')
          .doc(id)
          .collection('attendees');

      QuerySnapshot<Map<String, dynamic>> attendeeSnap;
      try {
        attendeeSnap = await attendees
            .get(const GetOptions(source: Source.server))
            .timeout(const Duration(seconds: 4));
      } catch (_) {
        try {
          attendeeSnap = await attendees
              .get(const GetOptions(source: Source.cache))
              .timeout(const Duration(seconds: 2));
        } catch (_) {
          continue;
        }
      }

      if (attendeeSnap.docs.isEmpty) continue;
      WriteBatch batch = _firestore.batch();
      int writes = 0;
      for (final QueryDocumentSnapshot<Map<String, dynamic>> attendee
          in attendeeSnap.docs) {
        final String studentId = attendee.id.trim();
        if (studentId.isEmpty) continue;
        final DocumentReference<Map<String, dynamic>> dest = canonicalRef
            .collection('attendees')
            .doc(studentId);
        batch.set(dest, attendee.data(), SetOptions(merge: true));
        writes++;
        if (writes >= 450) {
          try {
            await batch.commit();
          } catch (_) {
            // Best-effort.
          }
          batch = _firestore.batch();
          writes = 0;
        }
      }
      if (writes > 0) {
        try {
          await batch.commit();
        } catch (_) {
          // Best-effort.
        }
      }
    }

    // Server-side cleanup: delete old session docs + subcollections.
    try {
      final HttpsCallable callable = FirebaseFunctions.instance.httpsCallable(
        'mergeAttendanceSessionAttemptsForSlot',
      );
      await callable
          .call(<String, dynamic>{
            'canonicalSessionId': canonicalSessionId,
            'sessionIds': sessionIds.toList(growable: false),
          })
          .timeout(const Duration(seconds: 8));
    } catch (_) {
      // Offline or insufficient permissions: keep best-effort local merge.
    }
  }

  Future<void> _ensureSessionDocumentBestEffort() async {
    try {
      // Time-box this so offline sessions don't hang camera startup.
      // IMPORTANT: When offline, attempting a server read first can consume the
      // whole time budget and prevent local session creation. If that happens,
      // _sessionDocId remains null and captures are never queued for sync.
      //
      // Do a fast offline-first upsert (cache/local only) so the session exists
      // immediately, then best-effort reconcile with the server in the
      // background.
      await _ensureSessionDocumentOfflineFirst().timeout(
        const Duration(seconds: 2),
      );
      unawaited(() async {
        try {
          await _ensureSessionDocument();
        } catch (_) {
          // Best-effort only.
        }
      }());
    } catch (_) {
      // Offline or slow network: skip for now.
    }
  }

  Future<void> _ensureSessionDocumentOfflineFirst() async {
    if (_sessionDocId != null) return;

    // Anchor the pointer ID to the date at session launch (deterministic across retries).
    _sessionPointerDateKey ??= _dateKey(_now());

    final User? user = FirebaseAuth.instance.currentUser;
    final String? uid = user?.uid;
    if (uid == null || uid.isEmpty) {
      throw StateError('Not signed in.');
    }

    final DateTime now = _now();
    final String dateKey = _sessionPointerDateKey ?? _dateKey(now);
    final String canonicalSessionId = _buildCanonicalSessionId(
      instructorId: uid,
      classId: widget.config.classId,
      dateKey: dateKey,
      scheduleKey: widget.config.scheduleKey,
    );

    final DateTime scheduledStart = _dateWithTime(now, widget.config.start);
    DateTime scheduledEnd = _dateWithTime(now, widget.config.end);
    if (scheduledEnd.isBefore(scheduledStart)) {
      scheduledEnd = scheduledEnd.add(const Duration(days: 1));
    }
    _scheduledEndAt = scheduledEnd;

    final DocumentReference<Map<String, dynamic>> canonicalRef = _firestore
        .collection('attendanceSessions')
        .doc(canonicalSessionId);

    // Cache/local-only probe: if we already have a local copy, reuse it.
    try {
      final DocumentSnapshot<Map<String, dynamic>> snap = await canonicalRef
          .get(const GetOptions(source: Source.cache))
          .timeout(const Duration(milliseconds: 500));
      if (snap.exists) {
        _sessionDocId = canonicalSessionId;
        _applySessionMetaFromDoc(snap.data());
      }
    } catch (_) {
      // Ignore cache probe failures.
    }

    // Always ensure the session doc exists locally (queued for sync).
    await canonicalRef.set(<String, dynamic>{
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
      'scheduleKey': widget.config.scheduleKey,
      'dateKey': dateKey,
      'scheduledStartAt': Timestamp.fromDate(scheduledStart),
      'scheduledEndAt': Timestamp.fromDate(scheduledEnd),
      'instructorId': uid,
      'instructorEmail': user?.email,
      'status': 'active',
      'startedAt': FieldValue.serverTimestamp(),
      'createdAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    _sessionDocId ??= canonicalSessionId;

    // Best-effort pointer write (also queued for sync).
    try {
      await _upsertSessionPointer(status: 'active');
    } catch (_) {
      // Best-effort only.
    }
  }

  Future<void> _loadRecordedAttendeesBestEffort() async {
    final String? sessionId = _sessionDocId;
    if (sessionId == null || sessionId.trim().isEmpty) {
      return;
    }

    final CollectionReference<Map<String, dynamic>> attendees = _firestore
        .collection('attendanceSessions')
        .doc(sessionId)
        .collection('attendees');

    QuerySnapshot<Map<String, dynamic>> snapshot;
    try {
      snapshot = await attendees
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 4));
    } catch (_) {
      try {
        snapshot = await attendees
            .get(const GetOptions(source: Source.cache))
            .timeout(const Duration(seconds: 2));
      } catch (_) {
        return;
      }
    }

    if (!mounted) return;
    setState(() {
      for (final QueryDocumentSnapshot<Map<String, dynamic>> doc
          in snapshot.docs) {
        final String uid = doc.id.trim();
        if (uid.isEmpty) continue;

        _capturedStudentIds.add(uid);

        final Object? statusRaw = doc.data()['status'];
        final String status = (statusRaw as String?)?.trim() ?? '';
        if (status.isNotEmpty) {
          _recordedStatuses[uid] = status;

          final Object? minutesLateRaw = doc.data()['minutesLate'];
          if (minutesLateRaw is num) {
            final int v = minutesLateRaw.round();
            if (v > 0) {
              _recordedLateMinutes[uid] = v;
            }
          }
        }
      }
    });
    // Merge any pending offline ops for this session so the UI reflects
    // captures/upserts performed while offline before they are flushed.
    try {
      await _applyPendingOutboxOpsToState(sessionId);
    } catch (_) {
      // Best-effort only.
    }
  }

  Future<void> _applyPendingOutboxOpsToState(String sessionId) async {
    try {
      List<Map<String, Object?>> ops =
          await AttendanceOutboxService.instance
              .pendingOperationsForSession(sessionId);
      // If no exact matches found, try a fuzzy fallback that matches
      // by instructor/class/date segments. This addresses cases where
      // a legacy or resume session id differs from the canonical id.
      if (ops.isEmpty) {
        ops = await AttendanceOutboxService.instance
            .pendingOperationsForSession(sessionId, fuzzy: true);
        if (ops.isNotEmpty) {
          try {
            debugPrint('AttendanceSessionPage: applied fuzzy outbox fallback for $sessionId (found ${ops.length} ops)');
          } catch (_) {}
        }
      }
      if (ops.isEmpty) return;
      if (!mounted) return;
      setState(() {
        _pendingCapturedStudentIds.clear();
        for (final Map<String, Object?> payload in ops) {
          final String type = (payload['type'] ?? '').toString();
          if (type == 'attendee') {
            final String studentId =
                (payload['studentId'] ?? '').toString().trim();
            if (studentId.isEmpty) continue;

            final String? status = (payload['status'] as String?)?.trim();
            if (status != null && status.isNotEmpty) {
              _recordedStatuses[studentId] = status;
            }

            // Mark as captured locally so the roster disables the student.
            _capturedStudentIds.add(studentId);
            _pendingCapturedStudentIds.add(studentId);

            final Object? minutesLateRaw = payload['minutesLate'];
            if (minutesLateRaw is num) {
              _recordedLateMinutes[studentId] = minutesLateRaw.round();
            }
          } else if (type == 'capture') {
            final String? matchUserId =
                (payload['matchUserId'] as String?)?.trim();
            if (matchUserId != null && matchUserId.isNotEmpty) {
              _capturedStudentIds.add(matchUserId);
              _pendingCapturedStudentIds.add(matchUserId);
              final String? attendanceStatus =
                  (payload['attendanceStatus'] as String?)?.trim();
              if (attendanceStatus != null &&
                  attendanceStatus.isNotEmpty &&
                  !_recordedStatuses.containsKey(matchUserId)) {
                _recordedStatuses[matchUserId] = attendanceStatus;
              }
            }
          }
        }
      });
    } catch (_) {
      // Best-effort only.
    }
  }

  Future<void> _loadRosterEmbeddings() async {
    // Try to load a cached roster first so offline sessions can still run.
    // This is best-effort and will be replaced by fresh VPS data when online.
    await _loadRosterEmbeddingsFromCacheBestEffort();

    final int cachedRosterCountBeforeRefresh = _roster.length;

    final CollectionReference<Map<String, dynamic>> usersCollection = _firestore
        .collection('users');
    final Query<Map<String, dynamic>> baseQuery = usersCollection.where(
      'role',
      isEqualTo: 'student',
    );

    final String sectionLabel = (widget.config.section ?? '').trim();
    Query<Map<String, dynamic>> query = baseQuery;
    if (sectionLabel.isNotEmpty) {
      query = query.where('section', isEqualTo: sectionLabel);
    }

    QuerySnapshot<Map<String, dynamic>> snapshot;
    try {
      snapshot = await query
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 6));
    } catch (_) {
      try {
        snapshot = await query
            .get(const GetOptions(source: Source.cache))
            .timeout(const Duration(seconds: 3));
      } catch (e) {
        // Keep empty snapshot; fallbacks below may succeed.
        snapshot = await query.get(const GetOptions(source: Source.cache));
      }
    }

    // If a section is provided but the exact-match query returns nothing,
    // fall back to a best-effort client-side filter. This avoids common
    // mismatches caused by spacing/casing differences in stored section labels.
    if (sectionLabel.isNotEmpty && snapshot.docs.isEmpty) {
      try {
        final QuerySnapshot<Map<String, dynamic>> fallback = await baseQuery
            .get(const GetOptions(source: Source.server))
            .timeout(const Duration(seconds: 6));
        snapshot = fallback;
      } catch (_) {
        try {
          final QuerySnapshot<Map<String, dynamic>> fallback = await baseQuery
              .get(const GetOptions(source: Source.cache))
              .timeout(const Duration(seconds: 3));
          snapshot = fallback;
        } catch (e) {
          // Keep the empty snapshot.
        }
      }
    }

    // If we still have no results, fall back to a broad users fetch and
    // client-side filtering. This helps when stored role/section values
    // have casing/spacing mismatches (e.g., "Student" vs "student").
    if (snapshot.docs.isEmpty) {
      // Broad fallback: fetch more users and filter client-side.
      // This handles legacy schemas where role/section are missing or
      // differently-cased.
      try {
        snapshot = await usersCollection
            .orderBy(FieldPath.documentId)
            .limit(1000)
            .get(const GetOptions(source: Source.server))
            .timeout(const Duration(seconds: 8));
      } catch (_) {
        try {
          snapshot = await usersCollection
              .orderBy(FieldPath.documentId)
              .limit(1000)
              .get(const GetOptions(source: Source.cache))
              .timeout(const Duration(seconds: 4));
        } catch (e) {
          // Keep empty.
        }
      }
    }

    final List<QueryDocumentSnapshot<Map<String, dynamic>>> candidateDocs =
        snapshot.docs
            .where((QueryDocumentSnapshot<Map<String, dynamic>> doc) {
              return _isStudentProfile(doc.data());
            })
            .toList(growable: false);

    bool usedSectionFallback = false;
    List<QueryDocumentSnapshot<Map<String, dynamic>>> rosterDocs =
        candidateDocs;
    if (sectionLabel.isNotEmpty) {
      final String normalizedWantedSection = _normalizeLabel(sectionLabel);
      rosterDocs = candidateDocs
          .where((QueryDocumentSnapshot<Map<String, dynamic>> doc) {
            final Map<String, dynamic> data = doc.data();
            final Object? rawSection =
                data['section'] ?? data['Section'] ?? data['SECTION'];
            final String normalizedActualSection = _normalizeLabel(
              rawSection?.toString() ?? '',
            );
            return normalizedActualSection == normalizedWantedSection;
          })
          .toList(growable: false);

      // If section filtering results in no matches but we do have student
      // profiles, fall back to scanning all students. This prevents a
      // zero-roster session when section labels are missing/mismatched.
      if (rosterDocs.isEmpty && candidateDocs.isNotEmpty) {
        rosterDocs = candidateDocs;
        usedSectionFallback = true;
      }
    }

    try {
      final _RosterEmbeddingsFetchOutcome outcome =
          await _fetchRosterEmbeddingsFromVps(rosterDocs);
      final List<_RecognizedStudent> roster = outcome.roster;

      // If we already loaded a cached roster and the refresh yields an empty
      // roster (common when offline and Firestore/VPS cannot be reached), keep
      // the cached roster so offline mode can still function.
      if (roster.isEmpty && cachedRosterCountBeforeRefresh > 0) {
        _updateStatus(
          'Offline mode: keeping cached roster ($cachedRosterCountBeforeRefresh).',
        );
        return;
      }

      await _saveRosterEmbeddingsToCacheBestEffort(roster);

      if (mounted) {
        setState(() {
          _roster = roster;
        });
      }

      if (roster.isEmpty) {
        if (candidateDocs.isEmpty) {
          _updateStatus(
            sectionLabel.isEmpty
                ? 'No students found to scan.'
                : 'No students found for section "$sectionLabel".',
          );
        } else if (usedSectionFallback) {
          _updateStatus(
            'No students loaded for recognition. Section "$sectionLabel" did not match any student profiles, and embeddings failed to load. '
            'Try fixing section labels or scanning without a section filter.',
          );
        } else if (outcome.forbidden > 0) {
          _updateStatus(
            'Could not load roster embeddings. Permission denied by VPS for ${outcome.forbidden} students. '
            'Sign out/in to refresh your token, and ensure your account has the instructor/admin claim.',
          );
        } else if (outcome.failed > 0) {
          _updateStatus(
            'No students loaded for recognition. ${outcome.failed} embeddings failed to load. Check VPS connectivity.',
          );
        } else if (outcome.missing > 0) {
          _updateStatus(
            'No students loaded for recognition. ${outcome.missing} not enrolled yet.',
          );
        } else {
          _updateStatus(
            sectionLabel.isEmpty
                ? 'No students loaded for recognition. Check connection and enrollment.'
                : 'No students loaded for section "$sectionLabel". Check section labels and enrollment.',
          );
        }
      } else if (usedSectionFallback) {
        _updateStatus(
          'Loaded ${roster.length} students for recognition. Section "$sectionLabel" did not match any profiles, so scanning all students.',
        );
      } else if (outcome.failed > 0) {
        _updateStatus(
          'Loaded ${roster.length} students for recognition. ${outcome.failed} failed to load embeddings.',
        );
      } else if (outcome.missing > 0) {
        _updateStatus(
          'Loaded ${roster.length} students for recognition. ${outcome.missing} not enrolled yet.',
        );
      } else if (outcome.forbidden > 0) {
        _updateStatus(
          'Loaded ${roster.length} students for recognition. ${outcome.forbidden} forbidden (check instructor/admin claim).',
        );
      } else {
        // Successful refresh with no caveats; replace any cached-roster banner.
        _updateStatus('Loaded ${roster.length} students for recognition.');
      }
    } catch (error, stackTrace) {
      debugPrint('Roster load failed: $error\n$stackTrace');
      if (mounted) {
        // If we have a cached roster, keep it; otherwise fall back to empty.
        if (_roster.isEmpty) {
          setState(() {
            _roster = <_RecognizedStudent>[];
          });
        }
        final DateTime? cachedAt = _rosterCacheUpdatedAtUtc;
        final String cachedLine = cachedAt == null
            ? ''
            : ' Using cached roster (saved ${cachedAt.toLocal()}).';
        _updateStatus('Failed to refresh roster for recognition.$cachedLine');
      }
    }
  }

  String _buildRosterCacheKey() {
    final String section = (widget.config.section ?? '').trim();
    final String normalizedSection = _normalizeSectionForCacheKey(section);
    // V2: section-only cache key.
    // The roster query is based on role + section, not classId, so including
    // classId prevents offline re-use (and breaks offline-mode preparation).
    return 'roster_section_$normalizedSection';
  }

  String _buildLegacyRosterCacheKey() {
    final String classId = widget.config.classId.trim();
    final String section = (widget.config.section ?? '').trim();
    final String normalizedSection = _normalizeSectionForCacheKey(section);
    return 'roster_${classId}_$normalizedSection';
  }

  String _normalizeSectionForCacheKey(String sectionLabel) {
    final String section = sectionLabel.trim();
    if (section.isEmpty) return 'all';
    final String lowered = section.toLowerCase();
    final String dashed = lowered.replaceAll(
      RegExp('[\u2010\u2011\u2012\u2013\u2014\u2212]'),
      '-',
    );
    return dashed.replaceAll(RegExp(r'\s+'), '-');
  }

  String _safeRosterCacheKey(String key) {
    final String normalized = key.trim().toLowerCase();
    final String safe = normalized.replaceAll(RegExp(r'[^a-z0-9._-]+'), '_');
    return safe.isEmpty ? 'default' : safe;
  }

  List<_RecognizedStudent> _parseRosterFromJson(Object? payload) {
    if (payload is! Map) return <_RecognizedStudent>[];
    final Object? rosterObj = payload['roster'];
    if (rosterObj is! List) return <_RecognizedStudent>[];

    final List<_RecognizedStudent> roster = <_RecognizedStudent>[];
    for (final Object? item in rosterObj) {
      if (item is! Map) continue;
      final String userId = (item['userId'] ?? '').toString().trim();
      final String displayName = (item['displayName'] ?? '').toString().trim();
      if (userId.isEmpty || displayName.isEmpty) continue;

      final Object? embObj = item['embeddings'];
      final Object? centroidObj = item['centroidUnit'];
      if (embObj is! List || centroidObj is! List) continue;

      final List<List<double>> embeddings = <List<double>>[];
      for (final Object? e in embObj) {
        if (e is! List) continue;
        final List<double> vec = e
            .whereType<num>()
            .map((num n) => n.toDouble())
            .toList(growable: false);
        if (vec.isNotEmpty) embeddings.add(vec);
      }
      final List<double> centroidUnit = centroidObj
          .whereType<num>()
          .map((num n) => n.toDouble())
          .toList(growable: false);
      if (embeddings.isEmpty || centroidUnit.isEmpty) continue;

      roster.add(
        _RecognizedStudent(
          userId: userId,
          displayName: displayName,
          embeddings: embeddings,
          centroidUnit: centroidUnit,
        ),
      );
    }

    roster.sort(
      (a, b) =>
          a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()),
    );
    return roster;
  }

  Future<void> _loadRosterEmbeddingsFromCacheBestEffort() async {
    try {
      final String primaryKey = _buildRosterCacheKey();
      final String legacyKey = _buildLegacyRosterCacheKey();

      String dashToUnderscore(String input) {
        // Some older caches ended up with '_' where newer code uses '-'
        // because of unicode dash sanitization differences.
        return input.replaceAll('-', '_');
      }

      String? jsonString = await _rosterCache.readJson(key: primaryKey);
      bool loadedFromLegacy = false;
      bool loadedFromVariant = false;

      if (jsonString == null || jsonString.trim().isEmpty) {
        final String safePrimary = _safeRosterCacheKey(primaryKey);
        if (safePrimary != primaryKey) {
          jsonString = await _rosterCache.readJson(key: safePrimary);
        }
      }

      // Compatibility: if prep wrote a cache whose effective filename uses
      // underscores, try a dash->underscore variant.
      if (jsonString == null || jsonString.trim().isEmpty) {
        final String underscored = dashToUnderscore(primaryKey);
        if (underscored != primaryKey) {
          jsonString = await _rosterCache.readJson(key: underscored);
          loadedFromVariant =
              jsonString != null && jsonString.trim().isNotEmpty;
        }
      }
      if (jsonString == null || jsonString.trim().isEmpty) {
        final String safeUnderscored = _safeRosterCacheKey(
          dashToUnderscore(primaryKey),
        );
        if (safeUnderscored.isNotEmpty && safeUnderscored != primaryKey) {
          jsonString = await _rosterCache.readJson(key: safeUnderscored);
          loadedFromVariant =
              jsonString != null && jsonString.trim().isNotEmpty;
        }
      }

      if (jsonString == null || jsonString.trim().isEmpty) {
        jsonString = await _rosterCache.readJson(key: legacyKey);
        loadedFromLegacy = jsonString != null && jsonString.trim().isNotEmpty;
      }
      if (jsonString == null || jsonString.trim().isEmpty) {
        final String safeLegacy = _safeRosterCacheKey(legacyKey);
        if (safeLegacy != legacyKey) {
          jsonString = await _rosterCache.readJson(key: safeLegacy);
          loadedFromLegacy = jsonString != null && jsonString.trim().isNotEmpty;
        }
      }

      if (jsonString == null || jsonString.trim().isEmpty) {
        final String underscoredLegacy = dashToUnderscore(legacyKey);
        if (underscoredLegacy != legacyKey) {
          jsonString = await _rosterCache.readJson(key: underscoredLegacy);
          loadedFromVariant =
              jsonString != null && jsonString.trim().isNotEmpty;
        }
      }
      if (jsonString == null || jsonString.trim().isEmpty) {
        final String safeUnderscoredLegacy = _safeRosterCacheKey(
          dashToUnderscore(legacyKey),
        );
        if (safeUnderscoredLegacy.isNotEmpty &&
            safeUnderscoredLegacy != legacyKey) {
          jsonString = await _rosterCache.readJson(key: safeUnderscoredLegacy);
          loadedFromVariant =
              jsonString != null && jsonString.trim().isNotEmpty;
        }
      }

      // Last resort: scan the cache directory for a matching roster_section_*
      // file. This fixes cases where the section label contained non-ascii
      // characters and the resulting on-disk filename does not match the
      // in-memory key variants.
      if (jsonString == null || jsonString.trim().isEmpty) {
        final String section = (widget.config.section ?? '').trim();
        if (section.isNotEmpty) {
          final String? found = await findRosterCacheJsonForSectionBestEffort(
            sectionLabel: section,
          );
          if (found != null && found.trim().isNotEmpty) {
            jsonString = found;
            loadedFromVariant = true;
          }
        }
      }

      if (jsonString == null || jsonString.trim().isEmpty) return;
      final Object? decoded = jsonDecode(jsonString);
      if (decoded is! Map) return;

      final Object? cachedAt = decoded['cachedAtUtc'];
      DateTime? cachedAtUtc;
      if (cachedAt is String) {
        cachedAtUtc = DateTime.tryParse(cachedAt);
      }

      final List<_RecognizedStudent> roster = _parseRosterFromJson(decoded);
      if (roster.isEmpty) return;

      // Migration: if we loaded an older per-class key, persist under the new
      // section-only key so future offline runs find it quickly.
      if (loadedFromLegacy || loadedFromVariant) {
        unawaited(_rosterCache.writeJson(key: primaryKey, json: jsonString));
        final String safePrimary = _safeRosterCacheKey(primaryKey);
        if (safePrimary != primaryKey) {
          unawaited(_rosterCache.writeJson(key: safePrimary, json: jsonString));
        }
      }

      if (!mounted) return;
      setState(() {
        _roster = roster;
        _rosterCacheUpdatedAtUtc = cachedAtUtc;
      });

      final String when = cachedAtUtc == null
          ? ''
          : ' (saved ${cachedAtUtc.toLocal()})';
      _updateStatus(
        'Offline mode: loaded cached roster (${roster.length})$when. Will refresh when online.',
      );
    } catch (_) {
      // Best-effort only.
    }
  }

  Future<void> _saveRosterEmbeddingsToCacheBestEffort(
    List<_RecognizedStudent> roster,
  ) async {
    if (roster.isEmpty) return;
    try {
      final String key = _buildRosterCacheKey();
      final String legacyKey = _buildLegacyRosterCacheKey();
      final Map<String, Object?> payload = <String, Object?>{
        'cachedAtUtc': DateTime.now().toUtc().toIso8601String(),
        'roster': roster
            .map(
              (s) => <String, Object?>{
                'userId': s.userId,
                'displayName': s.displayName,
                'embeddings': s.embeddings,
                'centroidUnit': s.centroidUnit,
              },
            )
            .toList(growable: false),
      };
      final String json = jsonEncode(payload);
      await _rosterCache.writeJson(key: key, json: json);
      final String safeKey = _safeRosterCacheKey(key);
      if (safeKey != key) {
        unawaited(_rosterCache.writeJson(key: safeKey, json: json));
      }
      // Back-compat for older builds that still include classId in the key.
      unawaited(_rosterCache.writeJson(key: legacyKey, json: json));
      final String safeLegacy = _safeRosterCacheKey(legacyKey);
      if (safeLegacy != legacyKey) {
        unawaited(_rosterCache.writeJson(key: safeLegacy, json: json));
      }
      _rosterCacheUpdatedAtUtc = DateTime.now().toUtc();
    } catch (_) {
      // Best-effort only.
    }
  }

  String _normalizeLabel(String input) {
    return input.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  }

  bool _isStudentRole(Object? rawRole) {
    if (rawRole == null) return false;
    if (rawRole is String) {
      final String normalized = _normalizeLabel(rawRole);
      return normalized == 'student' || normalized.contains('student');
    }
    if (rawRole is List) {
      for (final Object? v in rawRole) {
        if (v == null) continue;
        final String normalized = _normalizeLabel(v.toString());
        if (normalized == 'student' || normalized.contains('student')) {
          return true;
        }
      }
      return false;
    }
    final String normalized = _normalizeLabel(rawRole.toString());
    return normalized == 'student' || normalized.contains('student');
  }

  bool _isStudentProfile(Map<String, dynamic> data) {
    if (_isStudentRole(data['role'])) return true;
    final Object? rawStudentId =
        data['studentId'] ?? data['StudentId'] ?? data['Student ID'];
    if (rawStudentId is String) {
      return rawStudentId.trim().isNotEmpty;
    }
    if (rawStudentId != null) {
      final String s = rawStudentId.toString().trim();
      return s.isNotEmpty;
    }
    return false;
  }

  Future<_RosterEmbeddingsFetchOutcome> _fetchRosterEmbeddingsFromVps(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) async {
    const VpsEmbeddingsApiClient client = VpsEmbeddingsApiClient();
    const int batchSize = 8;

    Future<void> tryBootstrapInstructorClaimOnce() async {
      if (_attemptedInstructorClaimBootstrap) return;
      _attemptedInstructorClaimBootstrap = true;
      try {
        await FirebaseFunctions.instance
            .httpsCallable('bootstrapInstructorClaim')
            .call(<String, dynamic>{});
        await FirebaseAuth.instance.currentUser?.getIdToken(true);
      } catch (e) {
        debugPrint('bootstrapInstructorClaim failed: $e');
      }
    }

    final List<_RecognizedStudent> roster = <_RecognizedStudent>[];
    int missing = 0;
    int failed = 0;
    int forbidden = 0;
    String? firstForbiddenUid;
    String? firstFailedUid;
    final Set<String> forbiddenUids = <String>{};

    for (int i = 0; i < docs.length; i += batchSize) {
      final int end = math.min(i + batchSize, docs.length);
      final List<QueryDocumentSnapshot<Map<String, dynamic>>> batch = docs
          .sublist(i, end);

      final List<_SingleEmbeddingFetchOutcome> results = await Future.wait(
        batch.map((QueryDocumentSnapshot<Map<String, dynamic>> doc) async {
          try {
            VpsEmbeddingsRecord? record;
            try {
              record = await client.getEmbeddingForUid(
                doc.id,
                forceRefreshToken: false,
              );
            } on VpsEmbeddingsApiException catch (e) {
              if (e.statusCode == 401 || e.statusCode == 403) {
                // Common when custom claims were recently updated. Retry once
                // with a forced refresh.
                try {
                  record = await client.getEmbeddingForUid(
                    doc.id,
                    forceRefreshToken: true,
                  );
                } on VpsEmbeddingsApiException catch (e2) {
                  if (e2.statusCode == 403) {
                    // If the VPS checks custom claims (e.g. `instructor: true`) but
                    // the app only stored instructor role in Firestore, bootstrap
                    // the claim once and retry.
                    await tryBootstrapInstructorClaimOnce();
                    record = await client.getEmbeddingForUid(
                      doc.id,
                      forceRefreshToken: true,
                    );
                  } else {
                    rethrow;
                  }
                }
              } else {
                rethrow;
              }
            }
            if (record == null) {
              return const _SingleEmbeddingFetchOutcome.missing();
            }
            final List<List<double>> rawTemplates = record.embeddings.isNotEmpty
                ? record.embeddings
                : <List<double>>[record.embedding];
            final List<List<double>> templates = rawTemplates
                .map(_l2NormalizeVector)
                .where((List<double> v) => v.isNotEmpty)
                .toList(growable: false);
            if (templates.isEmpty) {
              return const _SingleEmbeddingFetchOutcome.failed();
            }
            final List<double> centroidUnit = _l2NormalizeVector(
              _averageVectors(templates),
            );
            final String displayName = _RecognizedStudent._resolveDisplayName(
              doc.data(),
              doc.id,
            );
            return _SingleEmbeddingFetchOutcome.student(
              _RecognizedStudent(
                userId: doc.id,
                displayName: displayName,
                embeddings: templates,
                centroidUnit: centroidUnit,
              ),
            );
          } on TimeoutException {
            return const _SingleEmbeddingFetchOutcome.failed();
          } on VpsEmbeddingsApiException catch (e) {
            if (e.statusCode == 404) {
              return const _SingleEmbeddingFetchOutcome.missing();
            }
            if (e.statusCode == 401 || e.statusCode == 403) {
              if (e.statusCode == 403) {
                await tryBootstrapInstructorClaimOnce();
              }
              firstForbiddenUid ??= doc.id;
              return const _SingleEmbeddingFetchOutcome.forbidden();
            }
            firstFailedUid ??= doc.id;
            return const _SingleEmbeddingFetchOutcome.failed();
          } catch (_) {
            firstFailedUid ??= doc.id;
            return const _SingleEmbeddingFetchOutcome.failed();
          }
        }),
      );

      for (int j = 0; j < results.length; j++) {
        final _SingleEmbeddingFetchOutcome outcome = results[j];
        if (outcome.student != null) {
          roster.add(outcome.student!);
        } else if (outcome.isMissing) {
          missing++;
        } else if (outcome.isForbidden) {
          forbidden++;
          forbiddenUids.add(batch[j].id);
        } else if (outcome.isFailed) {
          failed++;
        }
      }
    }

    // If we attempted to bootstrap an instructor claim during this run, some
    // early requests in the batch may have already returned 403 before the claim
    // was set + token refreshed. Retry those forbidden UIDs once.
    if (forbiddenUids.isNotEmpty && _attemptedInstructorClaimBootstrap) {
      int forbiddenAfterRetry = 0;
      String? firstForbiddenAfter;

      for (final QueryDocumentSnapshot<Map<String, dynamic>> doc in docs) {
        if (!forbiddenUids.contains(doc.id)) continue;
        try {
          final VpsEmbeddingsRecord? record = await client.getEmbeddingForUid(
            doc.id,
            forceRefreshToken: true,
          );
          if (record == null) {
            missing++;
            continue;
          }
          final List<List<double>> rawTemplates = record.embeddings.isNotEmpty
              ? record.embeddings
              : <List<double>>[record.embedding];
          final List<List<double>> templates = rawTemplates
              .map(_l2NormalizeVector)
              .where((List<double> v) => v.isNotEmpty)
              .toList(growable: false);
          if (templates.isEmpty) {
            failed++;
            continue;
          }
          final List<double> centroidUnit = _l2NormalizeVector(
            _averageVectors(templates),
          );
          final String displayName = _RecognizedStudent._resolveDisplayName(
            doc.data(),
            doc.id,
          );
          roster.add(
            _RecognizedStudent(
              userId: doc.id,
              displayName: displayName,
              embeddings: templates,
              centroidUnit: centroidUnit,
            ),
          );
        } on VpsEmbeddingsApiException catch (e) {
          if (e.statusCode == 404) {
            missing++;
            continue;
          }
          if (e.statusCode == 401 || e.statusCode == 403) {
            forbiddenAfterRetry++;
            firstForbiddenAfter ??= doc.id;
            continue;
          }
          failed++;
        } on TimeoutException {
          failed++;
        } catch (_) {
          failed++;
        }
      }

      forbidden = forbiddenAfterRetry;
      firstForbiddenUid = firstForbiddenUid ?? firstForbiddenAfter;
    }

    if (forbidden > 0 && firstForbiddenUid != null) {
      debugPrint(
        'Roster VPS fetch: forbidden=$forbidden (first uid=$firstForbiddenUid)',
      );
    }
    if (failed > 0 && firstFailedUid != null) {
      debugPrint(
        'Roster VPS fetch: failed=$failed (first uid=$firstFailedUid)',
      );
    }

    return _RosterEmbeddingsFetchOutcome(
      roster: roster,
      missing: missing,
      failed: failed,
      forbidden: forbidden,
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
      // Enrollment uses ResolutionPreset.medium; keep attendance verification
      // consistent to avoid low-detail crops causing mismatches.
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

  Future<void> _stopCameraStreamBestEffort() async {
    final CameraController? controller = _cameraController;
    if (controller == null) return;
    try {
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
    } catch (_) {
      // Best-effort only.
    }
  }

  Future<void> _disposeCameraBestEffort() async {
    final CameraController? controller = _cameraController;
    _cameraController = null;
    if (controller == null) return;
    try {
      await controller.stopImageStream();
    } catch (_) {
      // Best-effort only.
    }
    try {
      await controller.dispose();
    } catch (_) {
      // Best-effort only.
    }
  }

  Future<void> _enterVerifyMode(_RecognizedStudent student) async {
    if (_initializing || _isEndingSession) return;
    if (_shouldEndSessionNow()) {
      _showSnack('Session has reached the scheduled end time.');
      return;
    }
    if (!_captureEnabled) {
      _showSnack('Session is paused. Tap Continue session to resume.');
      return;
    }
    if (!_embeddingService.isReady) {
      _showSnack('Recognition model is still loading. Please wait a moment.');
      return;
    }
    if (_capturedStudentIds.contains(student.userId)) {
      _showSnack('Already recorded ${student.displayName}.');
      return;
    }

    setState(() {
      _viewMode = _AttendanceSessionViewMode.verify;
      _selectedStudent = student;
      _openingCamera = true;
      _statusMessage = 'Opening camera for ${student.displayName}...';
    });

    _resetProbeAndPendingState();

    try {
      if (_cameraController == null ||
          !(_cameraController?.value.isInitialized ?? false)) {
        await _initializeDeviceCamera();
      }

      // If the controller is already initialized from a previous verification,
      // restart the image stream so recognition resumes instantly.
      final CameraController? controller = _cameraController;
      if (controller != null &&
          controller.value.isInitialized &&
          !controller.value.isStreamingImages) {
        await controller.startImageStream(_processCameraImage);
      }
      if (!mounted) return;
      setState(() {
        _openingCamera = false;
        _statusMessage = 'Scanning for ${student.displayName}...';
      });
    } catch (e) {
      if (!mounted) return;
      await _disposeCameraBestEffort();
      setState(() {
        _openingCamera = false;
        _viewMode = _AttendanceSessionViewMode.roster;
        _selectedStudent = null;
        _statusMessage = 'Failed to open camera: $e';
      });
    }
  }

  Future<void> _exitVerifyMode({String? statusMessage}) async {
    // Keep the camera controller warm between student scans (much faster than
    // re-initializing). Stop the image stream so we don't keep processing
    // frames while showing the roster.
    await _stopCameraStreamBestEffort();
    if (!mounted) return;
    setState(() {
      _viewMode = _AttendanceSessionViewMode.roster;
      _selectedStudent = null;
      _statusMessage =
          statusMessage ?? 'Select a student from the roster to continue.';
    });
    _resetProbeAndPendingState();
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

    // Extra throttle to keep preview smooth.
    final DateTime now = _now();
    final bool isConfirming =
        _pendingStudentId != null || _pendingAmbiguousStudentId != null;
    final Duration minInterval = isConfirming
        ? _confirmingFrameProcessingInterval
        : _frameProcessingInterval;
    final DateTime? lastFrame = _lastFrameProcessedAt;
    if (lastFrame != null && now.difference(lastFrame) < minInterval) {
      return;
    }
    _lastFrameProcessedAt = now;

    _isProcessingFrame = true;
    try {
      final InputImage inputImage = _buildInputImage(image);
      final List<Face> faces = await detector.processImage(inputImage);
      if (faces.isEmpty) {
        _updateStatus('No face detected. Move face closer or farther');
      } else {
        Face primary = faces.first;
        if (faces.length > 1) {
          final List<Face> sorted = List<Face>.from(faces)
            ..sort((Face a, Face b) {
              final double areaA =
                  a.boundingBox.width.abs() * a.boundingBox.height.abs();
              final double areaB =
                  b.boundingBox.width.abs() * b.boundingBox.height.abs();
              return areaB.compareTo(areaA);
            });

          final double bestArea =
              sorted.first.boundingBox.width.abs() *
              sorted.first.boundingBox.height.abs();
          final double secondArea = sorted.length > 1
              ? (sorted[1].boundingBox.width.abs() *
                    sorted[1].boundingBox.height.abs())
              : 0.0;

          // Only proceed when one face is clearly dominant. This reduces
          // false positives when multiple students are in frame.
          const double dominanceRatio = 1.8;
          final bool dominant =
              secondArea <= 0.0 || (bestArea / secondArea) >= dominanceRatio;
          if (!dominant) {
            _lastCaptureTime = _now();
            _updateStatus(
              'Multiple faces detected. Only one student should be in frame.',
            );
            return;
          }
          primary = sorted.first;
        }

        // Skip expensive embedding generation if the face pose is extreme.
        final double yaw = primary.headEulerAngleY ?? 0.0;
        final double pitch = primary.headEulerAngleX ?? 0.0;
        const double maxYaw = 28;
        const double maxPitch = 28;
        if (yaw.abs() > maxYaw || pitch.abs() > maxPitch) {
          _lastCaptureTime = _now();
          _updateStatus('Look straight at the camera and hold still.');
          return;
        }

        final Rect bbox = _mapMlKitBboxToRaw(
          primary.boundingBox,
          rotationCompensation: _lastRotationCompensation,
          rawWidth: image.width.toDouble(),
          rawHeight: image.height.toDouble(),
        );

        final double faceRatio = _faceSizeRatio(
          bbox,
          rawWidth: image.width.toDouble(),
          rawHeight: image.height.toDouble(),
        );
        final bool isVerifying =
            _viewMode == _AttendanceSessionViewMode.verify &&
            _selectedStudent != null;
        final _DistanceTuning tuning = _distanceTuningForRatio(
          faceRatio,
          isVerification: isVerifying,
        );
        if (tuning.skipMatching) {
          _lastCaptureTime = _now();
          _updateStatus(
            tuning.guidanceMessage ??
                'Move closer to the camera (about half an arm length).',
          );
          return;
        }

        final Offset? leftEye = _mapMlKitLandmarkToRaw(
          primary.landmarks[FaceLandmarkType.leftEye],
          rotationCompensation: _lastRotationCompensation,
          rawWidth: image.width.toDouble(),
          rawHeight: image.height.toDouble(),
        );
        final Offset? rightEye = _mapMlKitLandmarkToRaw(
          primary.landmarks[FaceLandmarkType.rightEye],
          rotationCompensation: _lastRotationCompensation,
          rawWidth: image.width.toDouble(),
          rawHeight: image.height.toDouble(),
        );

        // Attendance matching is tuned for consistently aligned embeddings.
        // If we can't see both eyes clearly, skip this capture to avoid
        // low-quality probes that tend to cause "no match" loops or
        // occasional false positives.
        if (leftEye == null || rightEye == null) {
          _lastCaptureTime = _now();
          _updateStatus('Hold still and look at the camera.');
          return;
        }

        final List<double> embedding = await _embeddingService
            .generateEmbeddingAligned(
              image,
              bbox,
              leftEye: leftEye,
              rightEye: rightEye,
            );
        _lastCaptureTime = _now();
        final _RecognizedStudent? selected = _selectedStudent;
        if (_viewMode == _AttendanceSessionViewMode.verify &&
            selected != null) {
          await _handleSelectedStudentEmbeddingCapture(
            selected,
            embedding,
            tuning,
            sourceImage: image,
            sourceBbox: bbox,
            sourceLeftEye: leftEye,
            sourceRightEye: rightEye,
          );
        } else {
          // Safety fallback: if camera is running without a selected student,
          // run the legacy 1:N matcher.
          await _handleEmbeddingCapture(
            embedding,
            tuning,
            sourceImage: image,
            sourceBbox: bbox,
            sourceLeftEye: leftEye,
            sourceRightEye: rightEye,
          );
        }
      }
    } on FaceQualityException catch (error) {
      _lastCaptureTime = _now();
      _updateStatus(error.message);
    } catch (error) {
      debugPrint('Camera frame processing error: $error');
    } finally {
      _isProcessingFrame = false;
    }
  }

  bool _isWithinCooldown() {
    final DateTime? last = _lastCaptureTime;
    if (last == null) {
      return false;
    }
    final bool isConfirming =
        _pendingStudentId != null || _pendingAmbiguousStudentId != null;
    final Duration cooldown = isConfirming
        ? _confirmingCaptureCooldown
        : _captureCooldown;
    return _now().difference(last) < cooldown;
  }

  bool _shouldTryLegacyFallback(_MatchResult result, _DistanceTuning tuning) {
    if (result.student != null) {
      return result.rejectionReason == 'ambiguous';
    }
    final String reason = result.rejectionReason ?? '';
    if (reason.startsWith('insufficient-template-agreement')) return true;
    if (reason == 'below-threshold' || reason == 'single-template-too-weak') {
      final double? best = result.similarity;
      if (best == null || best.isNaN) return false;
      // Near-miss range where legacy templates may still match well.
      return best >= 0.45;
    }
    return false;
  }

  bool _shouldTryUnalignedFallback(_MatchResult result) {
    if (result.student != null) {
      return false;
    }

    final String reason = result.rejectionReason ?? '';
    if (reason != 'below-threshold' && reason != 'single-template-too-weak') {
      return false;
    }

    final double best = result.similarity ?? double.nan;
    if (!best.isFinite) return false;

    // Only attempt if we're in the near-miss range. This supports older
    // enrollments that were captured without eye alignment.
    if (best < 0.35) return false;

    final DateTime now = _now();
    final DateTime? last = _lastUnalignedFallbackAt;
    if (last != null && now.difference(last) < _unalignedFallbackCooldown) {
      return false;
    }

    _lastUnalignedFallbackAt = now;
    return true;
  }

  ({_MatchResult result, List<double> embedding, bool usedLegacy})
  _chooseBetweenNormalAndLegacy(
    _MatchResult normal,
    List<double> normalEmbedding,
    _MatchResult legacy,
    List<double> legacyEmbedding,
  ) {
    final _RecognizedStudent? normalStudent = normal.student;
    final _RecognizedStudent? legacyStudent = legacy.student;

    // If both modes produce confident (non-ambiguous) matches but disagree,
    // reject to avoid false positives.
    final bool normalAccepted =
        normalStudent != null && normal.rejectionReason != 'ambiguous';
    final bool legacyAccepted =
        legacyStudent != null && legacy.rejectionReason != 'ambiguous';
    if (normalAccepted && legacyAccepted) {
      if (normalStudent.userId != legacyStudent.userId) {
        return (
          result: _MatchResult(
            embedding: normal.embedding,
            similarity: normal.similarity,
            secondBestSimilarity: normal.secondBestSimilarity,
            rejectionReason: 'mode-disagreement',
          ),
          embedding: normalEmbedding,
          usedLegacy: false,
        );
      }
      // Same student: prefer normal.
      return (result: normal, embedding: normalEmbedding, usedLegacy: false);
    }

    // If legacy yields a strong, clearly separated match, let it override.
    if (legacyAccepted) {
      final double best = legacy.similarity ?? double.nan;
      final double second = legacy.secondBestSimilarity ?? double.nan;
      final double margin = (best.isNaN || second.isNaN)
          ? double.nan
          : (best - second);
      if (best.isFinite &&
          best >= _legacyOverrideMinSimilarity &&
          (second.isNaN || margin >= _legacyOverrideMinMargin)) {
        return (result: legacy, embedding: legacyEmbedding, usedLegacy: true);
      }
    }

    return (result: normal, embedding: normalEmbedding, usedLegacy: false);
  }

  Future<void> _handleEmbeddingCapture(
    List<double> embedding,
    _DistanceTuning tuning, {
    CameraImage? sourceImage,
    Rect? sourceBbox,
    Offset? sourceLeftEye,
    Offset? sourceRightEye,
  }) async {
    final DateTime captureTime = _now();

    // Keep a short rolling average of unit embeddings.
    final DateTime? lastSampleAt = _lastProbeSampleAt;
    if (lastSampleAt == null ||
        captureTime.difference(lastSampleAt) > _probeSmoothingResetAfter) {
      _probeHistoryUnit.clear();
    }
    _lastProbeSampleAt = captureTime;

    final List<double> unit = _l2NormalizeVector(embedding);
    if (unit.isNotEmpty) {
      _probeHistoryUnit.add(unit);
      if (_probeHistoryUnit.length > _probeSmoothingWindow) {
        _probeHistoryUnit.removeAt(0);
      }
    }

    final List<double> smoothed = _probeHistoryUnit.isEmpty
        ? embedding
        : _averageVectors(_probeHistoryUnit);

    _MatchResult result = _matchEmbedding(smoothed, tuning);
    List<double> embeddingUsed = smoothed;

    if (sourceImage != null &&
        sourceBbox != null &&
        sourceLeftEye != null &&
        sourceRightEye != null &&
        _shouldTryLegacyFallback(result, tuning)) {
      try {
        final List<double> legacyEmbedding = await _embeddingService
            .generateEmbeddingAlignedLegacy(
              sourceImage,
              sourceBbox,
              leftEye: sourceLeftEye,
              rightEye: sourceRightEye,
            );
        final _MatchResult legacyResult = _matchEmbedding(
          legacyEmbedding,
          tuning,
        );
        final chosen = _chooseBetweenNormalAndLegacy(
          result,
          smoothed,
          legacyResult,
          legacyEmbedding,
        );
        result = chosen.result;
        embeddingUsed = chosen.embedding;
      } catch (_) {
        // Best-effort only; keep normal result.
      }
    }

    // If the match is ambiguous, require the same top candidate to appear
    // multiple times within a short window before accepting.
    if (result.rejectionReason == 'ambiguous' && result.student != null) {
      final DateTime? expiresAt = _pendingAmbiguousExpiresAt;
      if (expiresAt != null && captureTime.isAfter(expiresAt)) {
        _pendingAmbiguousStudentId = null;
        _pendingAmbiguousConfirmations = 0;
        _pendingAmbiguousExpiresAt = null;
        _pendingAmbiguousStartedAt = null;
      }

      final String candidateId = result.student!.userId;
      if (_pendingAmbiguousStudentId == candidateId) {
        _pendingAmbiguousConfirmations++;
      } else {
        _pendingAmbiguousStudentId = candidateId;
        _pendingAmbiguousConfirmations = 1;
        _pendingAmbiguousStartedAt = captureTime;
      }
      _pendingAmbiguousExpiresAt = captureTime.add(
        _ambiguousConfirmationWindow,
      );

      final DateTime? startedAt = _pendingAmbiguousStartedAt;
      if (startedAt != null &&
          captureTime.difference(startedAt) > _maxConfirmationDuration) {
        _pendingAmbiguousStudentId = null;
        _pendingAmbiguousConfirmations = 0;
        _pendingAmbiguousExpiresAt = null;
        _pendingAmbiguousStartedAt = null;
        final String name = result.student?.displayName ?? 'this student';
        _updateStatus('Scanning for $name...');
        return;
      }

      if (_pendingAmbiguousConfirmations < _ambiguousConfirmationsRequired) {
        final String name = result.student?.displayName ?? 'this student';
        _updateStatus('Scanning for $name...');
        return;
      }

      // Do not auto-accept ambiguous matches.
      // Even if they are repeatable, top1≈top2 means the model cannot
      // confidently separate candidates and may flip between students.
      _pendingAmbiguousStudentId = null;
      _pendingAmbiguousConfirmations = 0;
      _pendingAmbiguousExpiresAt = null;
      _pendingAmbiguousStartedAt = null;
      final String name = result.student?.displayName ?? 'this student';
      _updateStatus('Scanning for $name...');
      return;
    } else if (result.student == null) {
      // Clear pending confirmation when nothing plausible matched.
      _pendingAmbiguousStudentId = null;
      _pendingAmbiguousConfirmations = 0;
      _pendingAmbiguousExpiresAt = null;
      _pendingAmbiguousStartedAt = null;

      _pendingStudentId = null;
      _pendingStudentName = null;
      _pendingConfirmations = 0;
      _pendingExpiresAt = null;
      _pendingStartedAt = null;
    }

    if (result.student == null) {
      final DateTime? last = _lastUnrecognizedTime;
      if (last != null &&
          captureTime.difference(last) < _unrecognizedCooldown) {
        return;
      }
      _lastUnrecognizedTime = captureTime;
      _updateStatus('Scanning for...');
      return;
    }

    // For all accepted matches, require a short confirmation window so we
    // don't record a student off a single noisy frame.
    if (result.student != null) {
      final DateTime? expiresAt = _pendingExpiresAt;
      if (expiresAt != null && captureTime.isAfter(expiresAt)) {
        _pendingStudentId = null;
        _pendingStudentName = null;
        _pendingConfirmations = 0;
        _pendingExpiresAt = null;
        _pendingStartedAt = null;
      }

      final String candidateId = result.student!.userId;
      final String candidateName =
          result.student?.displayName ?? 'this student';
      if (_pendingStudentId == candidateId) {
        _pendingConfirmations++;
      } else {
        // Strict: if the top match flips, reset confirmation.
        // This reduces the chance of recording the same face as multiple
        // students when the embedding is noisy.
        _pendingStudentId = candidateId;
        _pendingStudentName = candidateName;
        _pendingConfirmations = 1;
        _pendingStartedAt = captureTime;
      }
      _pendingExpiresAt = captureTime.add(_confirmationWindow);

      final DateTime? startedAt = _pendingStartedAt;
      if (startedAt != null &&
          captureTime.difference(startedAt) > _maxConfirmationDuration) {
        _pendingStudentId = null;
        _pendingStudentName = null;
        _pendingConfirmations = 0;
        _pendingExpiresAt = null;
        _pendingStartedAt = null;
        final String name = _pendingStudentName ?? candidateName;
        _updateStatus('Scanning for $name...');
        return;
      }

      final int requiredConfirmations = _requiredConfirmationsFor(
        result,
        tuning,
      );
      if (_pendingConfirmations < requiredConfirmations) {
        final String name = _pendingStudentName ?? candidateName;
        _updateStatus('Scanning for $name...');
        return;
      }

      _pendingStudentId = null;
      _pendingStudentName = null;
      _pendingConfirmations = 0;
      _pendingExpiresAt = null;
      _pendingStartedAt = null;
    }

    if (result.student != null) {
      final String studentId = result.student!.userId;
      final String name = result.student?.displayName ?? 'this student';

      // Only recognize/persist a student once per session to avoid spam.
      if (_capturedStudentIds.contains(studentId)) {
        _updateStatus('Already recorded $name for this session.');
        return;
      }

      if (_shouldThrottleStudentCapture(studentId, captureTime)) {
        _updateStatus('Already recorded $name recently.');
        return;
      }

      _recordLocalCapture(result, captureTime);
      _capturedStudentIds.add(studentId);
      try {
        await _persistCapture(result, embeddingUsed, captureTime);
      } catch (_) {
        // If persistence fails, allow re-capture.
        _capturedStudentIds.remove(studentId);
        rethrow;
      }
      return;
    }
  }

  _MatchResult _matchEmbeddingAgainstStudent(
    List<double> embedding,
    _RecognizedStudent selected,
    _DistanceTuning tuning,
  ) {
    final List<double> probe = _l2NormalizeVector(embedding);
    if (probe.isEmpty) {
      return _MatchResult(embedding: embedding, similarity: -1);
    }
    if (selected.embeddings.isEmpty) {
      return _MatchResult(embedding: embedding);
    }

    double bestTemplate = -1;
    int hitCount = 0;
    for (final List<double> candidate in selected.embeddings) {
      final double similarity = _cosineSimilarityNormalized(probe, candidate);
      if (similarity > bestTemplate) {
        bestTemplate = similarity;
      }
      if (similarity >= _templateHitThreshold) {
        hitCount++;
      }
    }

    if (bestTemplate < tuning.similarityThreshold) {
      return _MatchResult(
        embedding: embedding,
        similarity: bestTemplate,
        rejectionReason: 'below-threshold',
      );
    }

    final int templateCount = selected.embeddings.length;
    if (templateCount <= 1) {
      if (bestTemplate < tuning.singleTemplateThreshold) {
        return _MatchResult(
          embedding: embedding,
          similarity: bestTemplate,
          rejectionReason: 'single-template-too-weak',
        );
      }
    } else {
      final int requiredHits = math.min(
        templateCount,
        templateCount >= 6 && tuning.minTemplateHits >= 2
            ? math.max(2, tuning.minTemplateHits)
            : tuning.minTemplateHits,
      );
      if (hitCount < requiredHits) {
        return _MatchResult(
          embedding: embedding,
          similarity: bestTemplate,
          rejectionReason:
              'insufficient-template-agreement ($hitCount/$requiredHits)',
        );
      }
    }

    final double confidence = _similarityToDisplayConfidence(bestTemplate);
    return _MatchResult(
      embedding: embedding,
      student: selected,
      similarity: bestTemplate,
      confidence: confidence,
    );
  }

  Future<void> _handleSelectedStudentEmbeddingCapture(
    _RecognizedStudent selected,
    List<double> embedding,
    _DistanceTuning tuning, {
    CameraImage? sourceImage,
    Rect? sourceBbox,
    Offset? sourceLeftEye,
    Offset? sourceRightEye,
  }) async {
    final DateTime captureTime = _now();

    // Keep a short rolling average of unit embeddings (same as 1:N flow).
    final DateTime? lastSampleAt = _lastProbeSampleAt;
    if (lastSampleAt == null ||
        captureTime.difference(lastSampleAt) > _probeSmoothingResetAfter) {
      _probeHistoryUnit.clear();
    }
    _lastProbeSampleAt = captureTime;

    final List<double> unit = _l2NormalizeVector(embedding);
    if (unit.isNotEmpty) {
      _probeHistoryUnit.add(unit);
      if (_probeHistoryUnit.length > _probeSmoothingWindow) {
        _probeHistoryUnit.removeAt(0);
      }
    }

    final List<double> smoothed = _probeHistoryUnit.isEmpty
        ? embedding
        : _averageVectors(_probeHistoryUnit);

    _MatchResult result = _matchEmbeddingAgainstStudent(
      smoothed,
      selected,
      tuning,
    );
    List<double> embeddingUsed = smoothed;

    if (sourceImage != null &&
        sourceBbox != null &&
        sourceLeftEye != null &&
        sourceRightEye != null &&
        _shouldTryLegacyFallback(result, tuning)) {
      try {
        final List<double> legacyEmbedding = await _embeddingService
            .generateEmbeddingAlignedLegacy(
              sourceImage,
              sourceBbox,
              leftEye: sourceLeftEye,
              rightEye: sourceRightEye,
            );
        final _MatchResult legacyResult = _matchEmbeddingAgainstStudent(
          legacyEmbedding,
          selected,
          tuning,
        );

        // Prefer normal if both accept; otherwise pick the one that accepts.
        if (legacyResult.student != null && result.student == null) {
          result = legacyResult;
          embeddingUsed = legacyEmbedding;
        }
      } catch (_) {
        // Best-effort only.
      }
    }

    // If we still can't match, try an unaligned embedding as a compatibility
    // fallback for older enrollments. Throttled to avoid doubling inference
    // cost on every frame.
    if (sourceImage != null &&
        sourceBbox != null &&
        _shouldTryUnalignedFallback(result)) {
      try {
        final List<double> unalignedEmbedding = await _embeddingService
            .generateEmbedding(sourceImage, sourceBbox);
        final _MatchResult unalignedResult = _matchEmbeddingAgainstStudent(
          unalignedEmbedding,
          selected,
          tuning,
        );

        if (unalignedResult.student != null && result.student == null) {
          result = unalignedResult;
          embeddingUsed = unalignedEmbedding;
        }
      } catch (_) {
        // Best-effort only.
      }
    }

    // If we are no longer verifying the same selected student, ignore.
    if (_viewMode != _AttendanceSessionViewMode.verify ||
        _selectedStudent?.userId != selected.userId) {
      return;
    }

    if (result.student == null) {
      // Clear pending confirmation for a mismatch.
      _pendingStudentId = null;
      _pendingStudentName = null;
      _pendingConfirmations = 0;
      _pendingExpiresAt = null;
      _pendingStartedAt = null;

      _updateStatus('Scanning for ${selected.displayName}...');
      return;
    }

    // Require a short confirmation window before persisting.
    final DateTime? expiresAt = _pendingExpiresAt;
    if (expiresAt != null && captureTime.isAfter(expiresAt)) {
      _pendingStudentId = null;
      _pendingStudentName = null;
      _pendingConfirmations = 0;
      _pendingExpiresAt = null;
      _pendingStartedAt = null;
    }

    final String candidateId = selected.userId;
    final String candidateName = selected.displayName;
    if (_pendingStudentId == candidateId) {
      _pendingConfirmations++;
    } else {
      _pendingStudentId = candidateId;
      _pendingStudentName = candidateName;
      _pendingConfirmations = 1;
      _pendingStartedAt = captureTime;
    }
    _pendingExpiresAt = captureTime.add(_confirmationWindow);

    final DateTime? startedAt = _pendingStartedAt;
    if (startedAt != null &&
        captureTime.difference(startedAt) > _maxConfirmationDuration) {
      _pendingStudentId = null;
      _pendingStudentName = null;
      _pendingConfirmations = 0;
      _pendingExpiresAt = null;
      _pendingStartedAt = null;
      _updateStatus('Scanning for ${selected.displayName}...');
      return;
    }

    final int requiredConfirmations = _requiredConfirmationsFor(result, tuning);
    if (_pendingConfirmations < requiredConfirmations) {
      _updateStatus('Scanning for ${selected.displayName}...');
      return;
    }

    _pendingStudentId = null;
    _pendingStudentName = null;
    _pendingConfirmations = 0;
    _pendingExpiresAt = null;
    _pendingStartedAt = null;

    // Only recognize/persist a student once per session.
    if (_capturedStudentIds.contains(candidateId)) {
      _updateStatus(
        'Already recorded ${selected.displayName} for this session.',
      );
      await _exitVerifyMode(
        statusMessage: 'Already recorded ${selected.displayName}.',
      );
      return;
    }

    if (_shouldThrottleStudentCapture(candidateId, captureTime)) {
      _updateStatus('Already recorded ${selected.displayName} recently.');
      return;
    }

    _recordLocalCapture(result, captureTime);
    _capturedStudentIds.add(candidateId);
    try {
      await _persistCapture(result, embeddingUsed, captureTime);
    } catch (_) {
      _capturedStudentIds.remove(candidateId);
      rethrow;
    }

    _showSnack('Recorded ${selected.displayName}.');
    await _exitVerifyMode(statusMessage: 'Recorded ${selected.displayName}.');
  }

  int _requiredConfirmationsFor(_MatchResult result, _DistanceTuning tuning) {
    int required = _confirmationsRequired;
    final double best = result.similarity ?? double.nan;
    final double second = result.secondBestSimilarity ?? double.nan;
    final double margin = (best.isNaN || second.isNaN)
        ? double.nan
        : best - second;

    // If we're only barely above threshold or not well separated, require a
    // little extra stability.
    if (best.isFinite && best < (tuning.similarityThreshold + 0.06)) {
      required = math.max(required, 4);
    }
    if (margin.isFinite && margin < 0.20) {
      required = math.max(required, 4);
    }
    return required;
  }

  _MatchResult _matchEmbedding(List<double> embedding, _DistanceTuning tuning) {
    if (_roster.isEmpty) {
      return _MatchResult(embedding: embedding);
    }

    final List<double> probe = _l2NormalizeVector(embedding);
    if (probe.isEmpty) {
      return _MatchResult(embedding: embedding, similarity: -1);
    }

    final Iterable<_RecognizedStudent> searchSpace;
    if (_roster.length <= _centroidPrefilterTopK) {
      searchSpace = _roster;
    } else {
      // Speed: prefilter by centroid similarity so we only do full template
      // scoring on the most likely candidates.
      final List<(_RecognizedStudent, double)> scored =
          <(_RecognizedStudent, double)>[];
      for (final _RecognizedStudent student in _roster) {
        if (student.embeddings.isEmpty) continue;
        if (student.centroidUnit.isEmpty) continue;
        final double sim = _cosineSimilarityNormalized(
          probe,
          student.centroidUnit,
        );
        scored.add((student, sim));
      }
      scored.sort((a, b) => b.$2.compareTo(a.$2));
      searchSpace = scored.take(_centroidPrefilterTopK).map((e) => e.$1);
    }

    _RecognizedStudent? bestCandidate;
    double bestScore = -1;
    double secondBestScore = -1;
    double bestCandidateBestTemplate = -1;
    int bestCandidateHitCount = 0;

    // Compare on a per-student basis.
    // Important: enrollment stores templates from multiple poses; using an
    // average of top-2 similarities can unfairly penalize correct matches.
    // We instead score by the best-matching template, and then use template-hit
    // count + margin to reduce false positives.
    for (final _RecognizedStudent student in searchSpace) {
      if (student.embeddings.isEmpty) continue;
      double bestTemplate = -1;
      int hitCount = 0;
      for (final List<double> candidate in student.embeddings) {
        final double similarity = _cosineSimilarityNormalized(probe, candidate);
        if (similarity > bestTemplate) {
          bestTemplate = similarity;
        }
        if (similarity >= _templateHitThreshold) {
          hitCount++;
        }
      }

      final double score = bestTemplate;
      if (score > bestScore) {
        secondBestScore = bestScore;
        bestScore = score;
        bestCandidate = student;
        bestCandidateBestTemplate = bestTemplate;
        bestCandidateHitCount = hitCount;
      } else if (score > secondBestScore) {
        secondBestScore = score;
      }
    }

    if (bestCandidate == null) {
      return _MatchResult(embedding: embedding);
    }

    // If we couldn't establish a meaningful second-best candidate (for example
    // due to an overly small search space), treat it as ambiguous unless the
    // match is extremely strong.
    if (secondBestScore < 0 && bestScore < 0.85) {
      final double confidence = _similarityToDisplayConfidence(bestScore);
      return _MatchResult(
        embedding: embedding,
        student: bestCandidate,
        similarity: bestScore,
        secondBestSimilarity: bestScore,
        confidence: confidence,
        rejectionReason: 'ambiguous',
      );
    }

    if (bestScore < tuning.similarityThreshold) {
      return _MatchResult(
        embedding: embedding,
        similarity: bestScore,
        secondBestSimilarity: secondBestScore,
        rejectionReason: 'below-threshold',
      );
    }

    final int templateCount = bestCandidate.embeddings.length;
    if (templateCount <= 1) {
      if (bestCandidateBestTemplate < tuning.singleTemplateThreshold) {
        return _MatchResult(
          embedding: embedding,
          similarity: bestScore,
          secondBestSimilarity: secondBestScore,
          rejectionReason: 'single-template-too-weak',
        );
      }
    } else {
      final int requiredHits = math.min(
        templateCount,
        templateCount >= 6
            ? math.max(2, tuning.minTemplateHits)
            : tuning.minTemplateHits,
      );
      if (bestCandidateHitCount < requiredHits) {
        return _MatchResult(
          embedding: embedding,
          similarity: bestScore,
          secondBestSimilarity: secondBestScore,
          rejectionReason:
              'insufficient-template-agreement ($bestCandidateHitCount/$requiredHits)',
        );
      }
    }

    final double margin = bestScore - secondBestScore;
    if (secondBestScore >= 0 && margin < _similarityMargin) {
      final double confidence = _similarityToDisplayConfidence(bestScore);
      return _MatchResult(
        embedding: embedding,
        student: bestCandidate,
        similarity: bestScore,
        secondBestSimilarity: secondBestScore,
        confidence: confidence,
        rejectionReason: 'ambiguous',
      );
    }

    final double confidence = _similarityToDisplayConfidence(bestScore);
    return _MatchResult(
      embedding: embedding,
      student: bestCandidate,
      similarity: bestScore,
      secondBestSimilarity: secondBestScore,
      confidence: confidence,
    );
  }

  static double _faceSizeRatio(
    Rect bbox, {
    required double rawWidth,
    required double rawHeight,
  }) {
    final double minDim = math.min(rawWidth, rawHeight);
    if (!minDim.isFinite || minDim <= 1) return 0;
    final double baseSize = math.max(bbox.width.abs(), bbox.height.abs());
    if (!baseSize.isFinite || baseSize <= 0) return 0;
    return baseSize / minDim;
  }

  _DistanceTuning _distanceTuningForRatio(
    double ratio, {
    required bool isVerification,
  }) {
    final double singleTemplateThreshold = isVerification
        ? _verifySingleTemplateThreshold
        : _singleTemplateThreshold;
    final int minTemplateHits = isVerification
        ? _verifyMinTemplateHits
        : _minTemplateHits;
    final double sweetSingleTemplateThreshold = isVerification
        ? _verifySweetSingleTemplateThreshold
        : _sweetSingleTemplateThreshold;
    final int sweetMinTemplateHits = isVerification
        ? _verifySweetMinTemplateHits
        : _sweetMinTemplateHits;

    if (ratio > 0 && ratio < _distanceTooFarRatio) {
      return _DistanceTuning(
        skipMatching: true,
        guidanceMessage:
            'Move closer to the camera (about half an arm length).',
        similarityThreshold: _similarityThreshold,
        singleTemplateThreshold: singleTemplateThreshold,
        minTemplateHits: minTemplateHits,
      );
    }

    if (ratio >= _distanceTooFarRatio && ratio <= _distanceSweetMaxRatio) {
      return _DistanceTuning(
        skipMatching: false,
        similarityThreshold: _sweetSimilarityThreshold,
        singleTemplateThreshold: sweetSingleTemplateThreshold,
        minTemplateHits: sweetMinTemplateHits,
      );
    }

    return _DistanceTuning(
      skipMatching: false,
      similarityThreshold: _similarityThreshold,
      singleTemplateThreshold: singleTemplateThreshold,
      minTemplateHits: minTemplateHits,
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
        : _recordedStatuses[result.student!.userId] ??
              _classifyAttendanceStatus(captureTime);

    final int minutesLate = (result.student == null)
        ? 0
        : (() {
            final String studentId = result.student!.userId;
            final String? existing = _recordedStatuses[studentId];
            if (existing != null && existing.isNotEmpty) {
              return _recordedLateMinutes[studentId] ?? 0;
            }
            if (attendanceStatus != 'late') {
              return 0;
            }
            return _computeLateMinutesBeyondGrace(captureTime);
          })();

    final int minutesAbsent = (result.student == null)
        ? 0
        : (() {
            final String studentId = result.student!.userId;
            final String? existing = _recordedStatuses[studentId];
            if (existing != null && existing.isNotEmpty) {
              return 0;
            }
            if (attendanceStatus != 'absent') {
              return 0;
            }
            return _computeSessionDurationMinutes();
          })();
    final DocumentReference<Map<String, dynamic>> sessionRef = _firestore
        .collection('attendanceSessions')
        .doc(sessionId);

    final String clientCaptureId =
        '${captureTime.toUtc().millisecondsSinceEpoch}_${++_clientCaptureSeq}';
    final String capturedAtLocalIso = captureTime.toIso8601String();

    try {
      await sessionRef
          .collection('captures')
          .doc(clientCaptureId)
          .set(<String, dynamic>{
            'clientCaptureId': clientCaptureId,
            'capturedAt': FieldValue.serverTimestamp(),
            'capturedAtLocal': capturedAtLocalIso,
            'matchUserId': result.student?.userId,
            'matchDisplayName': result.student?.displayName,
            'confidence': result.confidence,
            'similarity': result.similarity,
            'embedding': embedding,
            'attendanceStatus': attendanceStatus,
          }, SetOptions(merge: true));
    } catch (_) {
      await AttendanceOutboxService.instance.enqueueCapture(
        sessionId: sessionId,
        captureId: clientCaptureId,
        capturedAtLocalIso: capturedAtLocalIso,
        matchUserId: result.student?.userId,
        matchDisplayName: result.student?.displayName,
        confidence: result.confidence,
        similarity: result.similarity,
        embedding: embedding,
        attendanceStatus: attendanceStatus,
      );
      unawaited(AttendanceOutboxService.instance.flushBestEffort());
    }

    if (result.student != null) {
      final String studentId = result.student!.userId;
      final bool isFirstStatusForStudent = !_recordedStatuses.containsKey(
        studentId,
      );

      try {
        await sessionRef
            .collection('attendees')
            .doc(studentId)
            .set(<String, dynamic>{
              'displayName': result.student!.displayName,
              if (isFirstStatusForStudent)
                'firstCapturedAt': FieldValue.serverTimestamp(),
              if (isFirstStatusForStudent)
                'firstCapturedAtLocal': capturedAtLocalIso,
              'lastCapturedAt': FieldValue.serverTimestamp(),
              'confidence': result.confidence,
              if (isFirstStatusForStudent) 'status': attendanceStatus,
              if (isFirstStatusForStudent)
                'statusComputedAt': FieldValue.serverTimestamp(),
              if (isFirstStatusForStudent) 'minutesLate': minutesLate,
              if (isFirstStatusForStudent) 'minutesAbsent': minutesAbsent,
            }, SetOptions(merge: true));
      } catch (_) {
        await AttendanceOutboxService.instance.enqueueAttendeeUpsert(
          sessionId: sessionId,
          studentId: studentId,
          displayName: result.student!.displayName,
          isFirstStatusForStudent: isFirstStatusForStudent,
          capturedAtLocalIso: capturedAtLocalIso,
          confidence: result.confidence,
          status: attendanceStatus,
          minutesLate: minutesLate,
          minutesAbsent: minutesAbsent,
        );
        unawaited(AttendanceOutboxService.instance.flushBestEffort());
      }

      await _updateClassAttendanceStats(
        studentId: studentId,
        newStatus: attendanceStatus,
        lateMinutesBeyondGrace: minutesLate,
      );
    }

    try {
      await sessionRef.set(<String, dynamic>{
        'lastCaptureAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (_) {
      await AttendanceOutboxService.instance.enqueueSessionLastCaptureAt(
        sessionId: sessionId,
      );
      unawaited(AttendanceOutboxService.instance.flushBestEffort());
    }
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

    final String type = (config.scheduleType ?? '').trim().toLowerCase();
    final bool isLaboratory = type == 'laboratory' || type == 'lab';

    // Lecture rules:
    // - late at +15 minutes (inclusive)
    // - absent at +30 minutes (inclusive)
    // Laboratory rules:
    // - late after 30 minutes (so +31 minutes and beyond)
    // - absent at +60 minutes (inclusive)
    final DateTime absentThreshold = startDateTime.add(
      Duration(minutes: isLaboratory ? 60 : 30),
    );
    if (!captureTime.isBefore(absentThreshold)) {
      return 'absent';
    }

    final DateTime lateThreshold = startDateTime.add(
      Duration(minutes: isLaboratory ? 31 : 15),
    );
    return captureTime.isBefore(lateThreshold) ? 'present' : 'late';
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

  int _computeLateMinutesBeyondGrace(DateTime captureTime) {
    final DateTime scheduledStart = _dateWithTime(
      captureTime,
      widget.config.start,
    );
    final int sessionMinutes = _computeSessionDurationMinutes();
    if (sessionMinutes <= 0) {
      return 0;
    }

    final int actualLateMinutes = captureTime
        .difference(scheduledStart)
        .inMinutes;
    final int clampedActual = actualLateMinutes.clamp(0, sessionMinutes);

    final String type = (widget.config.scheduleType ?? '').trim().toLowerCase();
    final bool isLaboratory = type == 'laboratory' || type == 'lab';
    final int graceMinutes = isLaboratory ? 30 : 15;
    final int beyondGrace = clampedActual - graceMinutes;
    return beyondGrace > 0 ? beyondGrace : 0;
  }

  Future<void> _updateClassAttendanceStats({
    required String studentId,
    required String? newStatus,
    int? lateMinutesBeyondGrace,
  }) async {
    // Server is the source of truth for attendanceStats.
    // Keep local status tracking only to prevent duplicate captures.
    final String normalized = (newStatus ?? '').trim().toLowerCase();
    if (normalized.isEmpty) return;

    final String? previousStatus = _recordedStatuses[studentId];
    if (previousStatus == normalized) return;

    _recordedStatuses[studentId] = normalized;

    final int sessionMinutes = _computeSessionDurationMinutes();
    if (normalized == 'late') {
      final int lateMinutes = (lateMinutesBeyondGrace ?? 0).clamp(
        0,
        sessionMinutes,
      );
      if (lateMinutes > 0) {
        _recordedLateMinutes[studentId] = lateMinutes;
      } else {
        _recordedLateMinutes.remove(studentId);
      }
    } else {
      _recordedLateMinutes.remove(studentId);
    }
  }

  int _computeSessionDurationMinutes() {
    final DateTime ref = DateTime(2000, 1, 1);
    final DateTime start = _dateWithTime(ref, widget.config.start);
    DateTime end = _dateWithTime(ref, widget.config.end);
    if (!end.isAfter(start)) {
      end = end.add(const Duration(days: 1));
    }
    final int minutes = end.difference(start).inMinutes;
    return minutes > 0 ? minutes : 0;
  }

  Future<void> _markUncapturedStudentsAbsent() async {
    final List<_RecognizedStudent> roster = _roster;
    if (roster.isEmpty) {
      return;
    }

    final String? sessionId = _sessionDocId;
    final DocumentReference<Map<String, dynamic>>? sessionRef =
        (sessionId == null || sessionId.trim().isEmpty)
        ? null
        : _firestore.collection('attendanceSessions').doc(sessionId);
    final DateTime now = _now();
    final int sessionMinutes = _computeSessionDurationMinutes();

    final Set<String> countedStudentIds = _recordedStatuses.keys.toSet();
    final Iterable<_RecognizedStudent> uncaptured = roster.where(
      (_RecognizedStudent student) =>
          !countedStudentIds.contains(student.userId),
    );
    for (final _RecognizedStudent student in uncaptured) {
      // Persist an explicit attendee record for analytics + audit.
      if (sessionRef != null) {
        try {
          await sessionRef
              .collection('attendees')
              .doc(student.userId)
              .set(<String, dynamic>{
                'displayName': student.displayName,
                'status': 'absent',
                'statusComputedAt': FieldValue.serverTimestamp(),
                'markedAbsentAt': FieldValue.serverTimestamp(),
                'markedAbsentAtLocal': now.toIso8601String(),
                'minutesLate': 0,
                'minutesAbsent': sessionMinutes,
              }, SetOptions(merge: true));
        } catch (_) {
          // Best-effort only.
        }
      }

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

  Offset? _mapMlKitLandmarkToRaw(
    FaceLandmark? landmark, {
    required int rotationCompensation,
    required double rawWidth,
    required double rawHeight,
  }) {
    final dynamic pos = landmark?.position;
    if (pos == null) return null;

    final double x = (pos.x as num).toDouble();
    final double y = (pos.y as num).toDouble();
    if (rawWidth <= 0 || rawHeight <= 0) return Offset(x, y);

    Offset mapped;
    switch (rotationCompensation % 360) {
      case 90:
        mapped = Offset(rawWidth - y, x);
        break;
      case 180:
        mapped = Offset(rawWidth - x, rawHeight - y);
        break;
      case 270:
        mapped = Offset(y, rawHeight - x);
        break;
      case 0:
      default:
        mapped = Offset(x, y);
        break;
    }

    return Offset(
      mapped.dx.clamp(0.0, rawWidth),
      mapped.dy.clamp(0.0, rawHeight),
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
    if (!_recognitionSupported) {
      return;
    }
    setState(() {
      _captureEnabled = !_captureEnabled;
      _statusMessage = _captureEnabled
          ? 'Session live. We will attempt recognition automatically.'
          : 'Session paused. Tap continue to record students.';
    });

    _setSessionStatusBestEffort(_captureEnabled ? 'active' : 'paused');
  }

  Future<void> _handlePrimarySessionAction() async {
    if (_initializing || _isEndingSession) return;
    if (_shouldEndSessionNow()) {
      await _endSession();
      return;
    }
    _toggleCapture();
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
      await _firestore
          .collection('attendanceSessions')
          .doc(sessionId)
          .update(<String, dynamic>{
            'status': 'completed',
            'endedAt': FieldValue.serverTimestamp(),
            'effectiveEndedAt': _scheduledEndAt != null
                ? Timestamp.fromDate(_scheduledEndAt!)
                : FieldValue.serverTimestamp(),
          });
      await _upsertSessionPointer(status: 'completed', ended: true);
    } catch (_) {
      // Best-effort update only.
    } finally {
      // Important: only auto-mark absences when the session actually ran
      // within the scheduled window. If the instructor starts a session
      // outside the schedule (often for testing), the primary action can be
      // "End session now" immediately; auto-marking everyone absent in that
      // scenario creates misleading pre-filled attendance stats.
      final DateTime? startedAt = _sessionStartedAt;
      final DateTime? scheduledEnd = _scheduledEndAt;
      final bool startedOutsideWindow =
          startedAt != null &&
          scheduledEnd != null &&
          (startedAt.isAfter(scheduledEnd) ||
              startedAt.isAtSameMomentAs(scheduledEnd));

      if (!startedOutsideWindow) {
        await _markUncapturedStudentsAbsent();
      }
      _sessionClosed = true;
    }
  }

  Future<void> _pauseSessionBestEffort() async {
    if (_sessionClosed) return;
    if (_sessionDocId == null) return;
    await _setSessionStatusBestEffort('paused');
    await _upsertSessionPointer(status: 'paused');
  }

  bool _isDecisionStatus(String message) {
    return message.startsWith('Face detected') ||
        message.startsWith('Ambiguous match') ||
        message.startsWith('Scanning for') ||
        message.startsWith('No face detected') ||
        message.startsWith('Recognized') ||
        message.startsWith('Multiple faces') ||
        message.startsWith('Look straight') ||
        message.startsWith('Hold still') ||
        message.startsWith('Already recorded') ||
        message.startsWith('Move closer');
  }

  void _updateStatus(String message) {
    if (!mounted) return;
    if (_statusMessage == message) {
      return;
    }

    final DateTime now = _now();
    final DateTime? last = _lastStatusUpdatedAt;

    final bool decision = _isDecisionStatus(message);
    if (!decision &&
        last != null &&
        now.difference(last) < _statusUpdateMinInterval) {
      // Avoid UI rebuild storms while the camera stream is active.
      // Status messages are advisory; dropping some updates is fine.
      return;
    }

    if (decision) {
      final DateTime? lastDecision = _lastStatusUpdatedAt;
      if (lastDecision != null &&
          now.difference(lastDecision) < _decisionStatusUpdateMinInterval) {
        // Keep the status box stable enough to screenshot.
        return;
      }
      final String trimmed = message.trim();
      _lastStatusUpdatedAt = now;
      setState(() => _statusMessage = trimmed.isEmpty ? message : trimmed);
      return;
    }

    _lastStatusUpdatedAt = now;
    setState(() => _statusMessage = message);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_disposeCameraBestEffort());
    _sessionUiTimer?.cancel();
    _autoEndTimer?.cancel();
    _faceDetector?.close();
    _captureListController.dispose();
    unawaited(_pauseSessionBestEffort());
    super.dispose();
  }

  Future<void> _showRecognizedFaces() async {
    if (!mounted) return;
    final List<_AttendanceCapture> recognized = _recentCaptures
        .where((c) => c.matchDisplayName != null)
        .toList(growable: false);

    await showModalBottomSheet<void>(
      context: context,
      builder: (BuildContext context) {
        return SafeArea(
          child: _RecentCapturesList(
            captures: recognized,
            controller: _captureListController,
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final AttendanceSessionConfig config = widget.config;
    final ThemeData theme = Theme.of(context);

    // Full-screen loading state: hide the session UI (camera preview, overlays,
    // controls) until camera/model/roster are ready.
    if (_initializing) {
      return Scaffold(
        backgroundColor: theme.colorScheme.surface,
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const SizedBox(
                    width: 44,
                    height: 44,
                    child: CircularProgressIndicator(strokeWidth: 3),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _statusMessage ?? 'Preparing attendance session...',
                    style: theme.textTheme.titleMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'This may take a moment on first launch.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final bool inVerify = _viewMode == _AttendanceSessionViewMode.verify;
    final _RecognizedStudent? selected = _selectedStudent;
    final Widget preview = _buildPreviewPlaceholder();
    final bool showOvalGuide =
        !kIsWeb &&
        inVerify &&
        (_cameraController?.value.isInitialized ?? false);
    final bool showCenterMarker =
        !kIsWeb &&
        inVerify &&
        (_cameraController?.value.isInitialized ?? false);
    final bool endNow = _shouldEndSessionNow();
    final bool canToggleCapture = _recognitionSupported;
    final bool primaryEnabled =
        !_initializing && !_isEndingSession && (endNow || canToggleCapture);
    final IconData primaryIcon = endNow
        ? Icons.stop_circle_outlined
        : (canToggleCapture
              ? (_captureEnabled ? Icons.pause_circle : Icons.play_circle)
              : Icons.block);
    final String primaryLabel = endNow
        ? 'End session now'
        : (canToggleCapture
              ? (_captureEnabled ? 'Pause session' : 'Continue session')
              : 'Web not supported');

    return PopScope(
      canPop: !inVerify,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop) return;
        if (inVerify) {
          unawaited(_exitVerifyMode());
        }
      },
      child: Scaffold(
        appBar: AppBar(
          leading: inVerify
              ? IconButton(
                  tooltip: 'Back to roster',
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => _exitVerifyMode(),
                )
              : null,
          title: Text(
            inVerify
                ? (selected == null
                      ? 'Verify student'
                      : 'Verify ${selected.displayName}')
                : 'Select student',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: <Widget>[
            IconButton(
              tooltip: 'Recognized faces',
              onPressed: _showRecognizedFaces,
              icon: const Icon(Icons.people_alt_outlined),
            ),
            TextButton.icon(
              onPressed: primaryEnabled ? _handlePrimarySessionAction : null,
              icon: _isEndingSession
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(primaryIcon),
              label: Text(
                primaryLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
              ),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
            ),
          ],
        ),
        body: Column(
          children: <Widget>[
            Expanded(
              child: inVerify
                  ? ClaySurface(
                      margin: const EdgeInsets.all(8),
                      borderRadius: BorderRadius.circular(24),
                      child: Stack(
                        children: <Widget>[
                          Positioned.fill(child: preview),
                          if (showOvalGuide)
                            const Positioned.fill(
                              child: _OvalFaceGuideOverlay(),
                            ),
                          if (showCenterMarker)
                            Positioned.fill(
                              child: IgnorePointer(
                                child: ExcludeSemantics(
                                  child: Center(
                                    child: SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CustomPaint(
                                        painter: _CenterPlusPainter(
                                          theme.colorScheme.error.withValues(
                                            alpha: 0.95,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          if (_openingCamera)
                            const Positioned.fill(
                              child: IgnorePointer(
                                child: Center(
                                  child: CircularProgressIndicator(
                                    strokeWidth: 3,
                                  ),
                                ),
                              ),
                            ),
                          Positioned(
                            left: 12,
                            right: 12,
                            bottom: 12,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: theme.colorScheme.surface.withValues(
                                  alpha: 0.90,
                                ),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: theme.colorScheme.outlineVariant
                                      .withValues(alpha: 0.35),
                                ),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 10,
                                ),
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxHeight: 132,
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    mainAxisSize: MainAxisSize.min,
                                    children: <Widget>[
                                      Flexible(
                                        child: SingleChildScrollView(
                                          child: Text(
                                            _statusMessage ??
                                                'Align the student in front of the camera.',
                                            style: theme.textTheme.bodyMedium,
                                            softWrap: true,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                  : ClaySurface(
                      margin: const EdgeInsets.all(8),
                      borderRadius: BorderRadius.circular(24),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            Text(
                              _statusMessage ??
                                  'Select a student to start verification.',
                              style: theme.textTheme.bodyMedium,
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 12),
                            Expanded(
                              child: Builder(
                                builder: (BuildContext context) {
                                  final List<_RecognizedStudent> roster =
                                      List<_RecognizedStudent>.from(_roster)
                                        ..sort(
                                          (a, b) => a.displayName
                                              .toLowerCase()
                                              .compareTo(
                                                b.displayName.toLowerCase(),
                                              ),
                                        );
                                  if (roster.isEmpty) {
                                    return const Center(
                                      child: Text(
                                        'No students available in roster.',
                                        textAlign: TextAlign.center,
                                      ),
                                    );
                                  }

                                  return ListView.separated(
                                    itemCount: roster.length,
                                    separatorBuilder: (_, __) =>
                                        const Divider(height: 1),
                                    itemBuilder:
                                        (BuildContext context, int index) {
                                          final _RecognizedStudent student =
                                              roster[index];
                                          final bool recorded =
                                              _capturedStudentIds.contains(
                                            student.userId,
                                          );
                                          final bool pending =
                                              _pendingCapturedStudentIds
                                                  .contains(student.userId);

                                          return ListTile(
                                            title: Text(student.displayName),
                                            trailing: recorded
                                                ? (pending
                                                    ? Icon(
                                                        Icons.cloud_upload,
                                                        color: Colors.amber,
                                                      )
                                                    : Icon(
                                                        Icons.check_circle,
                                                        color: theme
                                                            .colorScheme
                                                            .primary,
                                                      ))
                                                : const Icon(
                                                    Icons.chevron_right,
                                                  ),
                                            enabled: !recorded &&
                                                !_initializing &&
                                                !_isEndingSession,
                                            onTap: recorded
                                                ? null
                                                : () => _enterVerifyMode(student),
                                          );
                                        },
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
            ),
            _SessionHeader(config: config, rosterCount: _roster.length),
          ],
        ),
      ),
    );
  }

  DateTime _computeScheduledEnd(DateTime reference) {
    final DateTime scheduledStart = _dateWithTime(
      reference,
      widget.config.start,
    );
    DateTime scheduledEnd = _dateWithTime(reference, widget.config.end);
    if (scheduledEnd.isBefore(scheduledStart)) {
      scheduledEnd = scheduledEnd.add(const Duration(days: 1));
    }
    return scheduledEnd;
  }

  String _dateKey(DateTime dt) {
    final String y = dt.year.toString().padLeft(4, '0');
    final String m = dt.month.toString().padLeft(2, '0');
    final String d = dt.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  String? _buildPointerId() {
    final String? uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || uid.isEmpty) return null;
    final String classId = widget.config.classId.trim();
    if (classId.isEmpty) return null;

    // IMPORTANT: Anchor the pointer doc ID to the session date key (derived
    // from the session's notion of "today"), not the Firestore server
    // timestamp. This keeps the instructor page listening to the correct
    // pointer doc and enables "Continue Session" reliably.
    final String dateKey = _sessionPointerDateKey ?? _dateKey(_now());
    return '${uid}_${classId}_$dateKey';
  }

  Future<void> _upsertSessionPointer({
    required String status,
    bool ended = false,
  }) async {
    final String? pointerId = _buildPointerId();
    final String? sessionId = _sessionDocId;
    if (pointerId == null || sessionId == null || sessionId.isEmpty) return;

    final DateTime now = _now();
    final DateTime scheduledStart = _dateWithTime(now, widget.config.start);
    DateTime scheduledEnd = _dateWithTime(now, widget.config.end);
    if (scheduledEnd.isBefore(scheduledStart)) {
      scheduledEnd = scheduledEnd.add(const Duration(days: 1));
    }

    try {
      await _firestore
          .collection(_kSessionPointerCollection)
          .doc(pointerId)
          .set(<String, dynamic>{
            'sessionId': sessionId,
            'classId': widget.config.classId,
            'instructorId': FirebaseAuth.instance.currentUser?.uid,
            'dateKey': _dateKey(now),
            'scheduleKey': widget.config.scheduleKey,
            'dayOfWeek': widget.config.dayOfWeek,
            'startHour': widget.config.start.hour,
            'startMinute': widget.config.start.minute,
            'endHour': widget.config.end.hour,
            'endMinute': widget.config.end.minute,
            'scheduledStartAt': Timestamp.fromDate(scheduledStart),
            'status': status,
            'scheduledEndAt': Timestamp.fromDate(scheduledEnd),
            'updatedAt': FieldValue.serverTimestamp(),
            if (ended)
              'endedAt': FieldValue.serverTimestamp()
            else
              'endedAt': FieldValue.delete(),
          }, SetOptions(merge: true));
    } catch (_) {
      // Best-effort only.
    }
  }

  Widget _buildPreviewPlaceholder() {
    if (kIsWeb) {
      return const Center(
        child: Text(
          'Web builds do not support face recognition.\nUse the Android app to scan faces.',
          textAlign: TextAlign.center,
        ),
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

class _OvalFaceGuideOverlay extends StatelessWidget {
  const _OvalFaceGuideOverlay();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color scrim = theme.colorScheme.scrim.withValues(alpha: 0.45);
    final Color stroke = theme.colorScheme.onSurface.withValues(alpha: 0.90);

    return IgnorePointer(
      child: CustomPaint(
        painter: _OvalFaceGuidePainter(scrimColor: scrim, strokeColor: stroke),
      ),
    );
  }
}

class _OvalFaceGuidePainter extends CustomPainter {
  const _OvalFaceGuidePainter({
    required this.scrimColor,
    required this.strokeColor,
  });

  final Color scrimColor;
  final Color strokeColor;

  static const double _aspectRatio = 0.78;

  Rect _computeGuideRect(Size size) {
    final Rect bounds = Offset.zero & size;
    if (bounds.isEmpty) return Rect.zero;

    final double maxWidth = size.width * 0.88;
    final double maxHeight = size.height * 0.82;

    double height = maxHeight;
    double width = height * _aspectRatio;
    if (width > maxWidth) {
      width = maxWidth;
      height = width / _aspectRatio;
    }

    return Rect.fromCenter(
      center: size.center(Offset.zero),
      width: width,
      height: height,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final Rect bounds = Offset.zero & size;
    final Rect guideRect = _computeGuideRect(size);
    if (guideRect.isEmpty) return;

    final Path maskPath = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(bounds)
      ..addOval(guideRect);

    final Paint dimPaint = Paint()
      ..color = scrimColor
      ..style = PaintingStyle.fill;
    canvas.drawPath(maskPath, dimPaint);

    final Paint borderPaint = Paint()
      ..color = strokeColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    canvas.drawOval(guideRect, borderPaint);
  }

  @override
  bool shouldRepaint(covariant _OvalFaceGuidePainter oldDelegate) {
    return oldDelegate.scrimColor != scrimColor ||
        oldDelegate.strokeColor != strokeColor;
  }
}

class _CenterPlusPainter extends CustomPainter {
  const _CenterPlusPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final Offset c = Offset(size.width / 2, size.height / 2);
    const double half = 7;
    canvas.drawLine(
      Offset(c.dx - half, c.dy),
      Offset(c.dx + half, c.dy),
      paint,
    );
    canvas.drawLine(
      Offset(c.dx, c.dy - half),
      Offset(c.dx, c.dy + half),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _CenterPlusPainter oldDelegate) {
    return oldDelegate.color != color;
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
    return ClaySurface(
      margin: EdgeInsets.zero,
      clipChild: false,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Recognized faces', style: theme.textTheme.titleMedium),
            SizedBox(
              height: 160,
              child: captures.isEmpty
                  ? const Center(
                      child: Text(
                        'No recognized faces yet. Position a student in front of the camera to begin.',
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

class _RosterEmbeddingsFetchOutcome {
  const _RosterEmbeddingsFetchOutcome({
    required this.roster,
    required this.missing,
    required this.failed,
    required this.forbidden,
  });

  final List<_RecognizedStudent> roster;
  final int missing;
  final int failed;
  final int forbidden;
}

class _SingleEmbeddingFetchOutcome {
  const _SingleEmbeddingFetchOutcome._({
    this.student,
    required this.isMissing,
    required this.isFailed,
    required this.isForbidden,
  });

  const _SingleEmbeddingFetchOutcome.student(_RecognizedStudent s)
    : this._(student: s, isMissing: false, isFailed: false, isForbidden: false);

  const _SingleEmbeddingFetchOutcome.missing()
    : this._(
        student: null,
        isMissing: true,
        isFailed: false,
        isForbidden: false,
      );

  const _SingleEmbeddingFetchOutcome.forbidden()
    : this._(
        student: null,
        isMissing: false,
        isFailed: false,
        isForbidden: true,
      );

  const _SingleEmbeddingFetchOutcome.failed()
    : this._(
        student: null,
        isMissing: false,
        isFailed: true,
        isForbidden: false,
      );

  final _RecognizedStudent? student;
  final bool isMissing;
  final bool isFailed;
  final bool isForbidden;
}

class _RecognizedStudent {
  const _RecognizedStudent({
    required this.userId,
    required this.displayName,
    required this.embeddings,
    required this.centroidUnit,
  });

  final String userId;
  final String displayName;
  final List<List<double>> embeddings;
  final List<double> centroidUnit;

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

class _DistanceTuning {
  const _DistanceTuning({
    required this.skipMatching,
    required this.similarityThreshold,
    required this.singleTemplateThreshold,
    required this.minTemplateHits,
    this.guidanceMessage,
  });

  final bool skipMatching;
  final double similarityThreshold;
  final double singleTemplateThreshold;
  final int minTemplateHits;
  final String? guidanceMessage;
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
