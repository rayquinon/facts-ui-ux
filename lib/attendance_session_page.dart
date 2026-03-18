import 'dart:async';
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
  static const double _similarityThreshold = 0.68;
  static const double _singleTemplateThreshold = 0.76;
  static const double _templateHitThreshold = 0.66;
  static const int _minTemplateHits = 2;
  static const double _similarityMargin = 0.14;
  static const double _confidenceSpan = 0.20;
  static const Duration _captureCooldown = Duration(seconds: 1);
  static const Duration _confirmingCaptureCooldown = Duration(
    milliseconds: 300,
  );
  static const Duration _duplicateCaptureCooldown = Duration(seconds: 10);
  static const Duration _unrecognizedCooldown = Duration(seconds: 4);
  static const Duration _ambiguousConfirmationWindow = Duration(seconds: 7);
  static const int _ambiguousConfirmationsRequired = 2;
  static const Duration _confirmationWindow = Duration(seconds: 6);
  static const int _confirmationsRequired = 2;
  static const Duration _maxConfirmationDuration = Duration(seconds: 12);
  static const Duration _autoEndAfterClassStart = Duration(minutes: 30);

  // Throttle camera frame processing to avoid UI jank.
  static const Duration _frameProcessingInterval = Duration(milliseconds: 180);
  static const Duration _confirmingFrameProcessingInterval = Duration(
    milliseconds: 120,
  );

  final FaceEmbeddingService _embeddingService = FaceEmbeddingService.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  CameraController? _cameraController;
  FaceDetector? _faceDetector;
  Timer? _sessionUiTimer;

  bool _isProcessingFrame = false;
  bool _captureEnabled = true;
  bool _isEndingSession = false;
  bool _initializing = true;
  String? _statusMessage;
  bool _attemptedInstructorClaimBootstrap = false;
  DateTime? _lastFrameProcessedAt;
  String? _sessionDocId;
  bool _sessionClosed = false;
  DateTime? _sessionStartedAt;
  DateTime? _lastCaptureTime;
  DateTime? _lastUnrecognizedTime;
  int _lastRotationCompensation = 0;

  bool get _recognitionSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  List<_RecognizedStudent> _roster = <_RecognizedStudent>[];
  final List<_AttendanceCapture> _recentCaptures = <_AttendanceCapture>[];
  final Map<String, String> _recordedStatuses = <String, String>{};
  final Map<String, DateTime> _lastStudentCaptureTimes = <String, DateTime>{};
  final Set<String> _capturedStudentIds = <String>{};
  final ScrollController _captureListController = ScrollController();

  String? _pendingAmbiguousStudentId;
  int _pendingAmbiguousConfirmations = 0;
  DateTime? _pendingAmbiguousExpiresAt;
  DateTime? _pendingAmbiguousStartedAt;

  String? _pendingStudentId;
  String? _pendingStudentName;
  int _pendingConfirmations = 0;
  int _pendingMismatchCount = 0;
  DateTime? _pendingExpiresAt;
  DateTime? _pendingStartedAt;

  @override
  void initState() {
    super.initState();
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
    // switch to "End session now" once the class-start cutoff is reached.
    _sessionUiTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!mounted) return;
      setState(() {});
    });

    _initializeSession();
  }

  DateTime _now() {
    final Duration? offset = widget.config.simulatedClockOffset;
    final DateTime systemNow = DateTime.now();
    return offset == null ? systemNow : systemNow.add(offset);
  }

  bool _shouldEndSessionNow() {
    final DateTime now = _now();
    final DateTime startedAt = _sessionStartedAt ?? now;
    final DateTime cutoff = startedAt.add(_autoEndAfterClassStart);
    return now.isAfter(cutoff) || now.isAtSameMomentAs(cutoff);
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

      if (!_recognitionSupported) {
        // Attendance recognition is not supported on web because the web build
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
        ]);
        return;
      }

      await _initializeDeviceCamera();

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

    // Anchor the session start time on Firestore server time.
    // This avoids device clock drift affecting the 30-minute cutoff.
    try {
      final DocumentSnapshot<Map<String, dynamic>> snap = await doc
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

  Future<void> _ensureSessionDocumentBestEffort() async {
    try {
      // Time-box this so offline sessions don't hang camera startup.
      await _ensureSessionDocument().timeout(const Duration(seconds: 3));
    } catch (_) {
      // Offline or slow network: skip for now.
    }
  }

  Future<void> _loadRosterEmbeddings() async {
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
      }
    } catch (error, stackTrace) {
      debugPrint('Roster load failed: $error\n$stackTrace');
      if (mounted) {
        setState(() {
          _roster = <_RecognizedStudent>[];
        });
        _updateStatus('Failed to load roster for recognition.');
      }
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
            final String displayName = _RecognizedStudent._resolveDisplayName(
              doc.data(),
              doc.id,
            );
            return _SingleEmbeddingFetchOutcome.student(
              _RecognizedStudent(
                userId: doc.id,
                displayName: displayName,
                embeddings: templates,
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
          final String displayName = _RecognizedStudent._resolveDisplayName(
            doc.data(),
            doc.id,
          );
          roster.add(
            _RecognizedStudent(
              userId: doc.id,
              displayName: displayName,
              embeddings: templates,
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
        _updateStatus('No face detected. Ask the student to step closer.');
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

        // If we can't see both eyes clearly, alignment is unreliable and can
        // increase false positives.
        if (leftEye == null || rightEye == null) {
          _lastCaptureTime = _now();
          _updateStatus('Hold still and face the camera.');
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
        await _handleEmbeddingCapture(embedding);
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

  Future<void> _handleEmbeddingCapture(List<double> embedding) async {
    _MatchResult result = _matchEmbedding(embedding);
    final DateTime captureTime = _now();
    bool confirmedViaAmbiguity = false;

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
        _updateStatus(
          'Could not confirm an ambiguous match. Try again (hold still, better lighting).',
        );
        return;
      }

      if (_pendingAmbiguousConfirmations < _ambiguousConfirmationsRequired) {
        final double best = result.similarity ?? double.nan;
        final double second = result.secondBestSimilarity ?? double.nan;
        final double margin = (best.isNaN || second.isNaN)
            ? double.nan
            : (best - second);
        final String name = result.student?.displayName ?? 'this student';
        final int remaining =
            _ambiguousConfirmationsRequired - _pendingAmbiguousConfirmations;
        _updateStatus(
          'Ambiguous match for $name. Scan again to confirm ($remaining left). '
          '(top1 ${best.toStringAsFixed(2)}, top2 ${second.toStringAsFixed(2)}, '
          'margin ${margin.toStringAsFixed(2)})',
        );
        return;
      }

      // Confirmed: accept this candidate.
      _pendingAmbiguousStudentId = null;
      _pendingAmbiguousConfirmations = 0;
      _pendingAmbiguousExpiresAt = null;
      _pendingAmbiguousStartedAt = null;
      confirmedViaAmbiguity = true;
      result = _MatchResult(
        embedding: result.embedding,
        student: result.student,
        similarity: result.similarity,
        secondBestSimilarity: result.secondBestSimilarity,
        confidence: result.confidence,
      );
    } else if (result.student == null) {
      // Clear pending confirmation when nothing plausible matched.
      _pendingAmbiguousStudentId = null;
      _pendingAmbiguousConfirmations = 0;
      _pendingAmbiguousExpiresAt = null;
      _pendingAmbiguousStartedAt = null;

      _pendingStudentId = null;
      _pendingStudentName = null;
      _pendingConfirmations = 0;
      _pendingMismatchCount = 0;
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
          final String reason = result.rejectionReason == 'ambiguous'
              ? ' Ambiguous match.'
              : '';
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

    // For all accepted matches, require a short confirmation window so we
    // don't record a student off a single noisy frame.
    if (!confirmedViaAmbiguity && result.student != null) {
      final DateTime? expiresAt = _pendingExpiresAt;
      if (expiresAt != null && captureTime.isAfter(expiresAt)) {
        _pendingStudentId = null;
        _pendingStudentName = null;
        _pendingConfirmations = 0;
        _pendingMismatchCount = 0;
        _pendingExpiresAt = null;
        _pendingStartedAt = null;
      }

      final String candidateId = result.student!.userId;
      final String candidateName =
          result.student?.displayName ?? 'this student';
      if (_pendingStudentId == candidateId) {
        _pendingConfirmations++;
        _pendingMismatchCount = 0;
      } else {
        // Allow a little bit of noise: if the top match flips briefly, keep the
        // original pending candidate so we can still reach 2 confirmations.
        _pendingMismatchCount++;
        const int mismatchTolerance = 1;
        if (_pendingStudentId == null ||
            _pendingMismatchCount > mismatchTolerance) {
          _pendingStudentId = candidateId;
          _pendingStudentName = candidateName;
          _pendingConfirmations = 1;
          _pendingMismatchCount = 0;
          _pendingStartedAt = captureTime;
        }
      }
      _pendingExpiresAt = captureTime.add(_confirmationWindow);

      final DateTime? startedAt = _pendingStartedAt;
      if (startedAt != null &&
          captureTime.difference(startedAt) > _maxConfirmationDuration) {
        _pendingStudentId = null;
        _pendingStudentName = null;
        _pendingConfirmations = 0;
        _pendingMismatchCount = 0;
        _pendingExpiresAt = null;
        _pendingStartedAt = null;
        final String name = _pendingStudentName ?? candidateName;
        _updateStatus(
          'Could not confirm $name. Try again (hold still, better lighting).',
        );
        return;
      }

      if (_pendingConfirmations < _confirmationsRequired) {
        final int remaining = _confirmationsRequired - _pendingConfirmations;
        final String name = _pendingStudentName ?? candidateName;
        _updateStatus('Hold still. Confirming $name... ($remaining left)');
        return;
      }

      _pendingStudentId = null;
      _pendingStudentName = null;
      _pendingConfirmations = 0;
      _pendingMismatchCount = 0;
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
    double bestScore = -1;
    double secondBestScore = -1;
    double bestCandidateBestTemplate = -1;
    int bestCandidateHitCount = 0;

    // Compare on a per-student basis. To reduce false positives, we:
    // - score each student by the average of their top-2 template similarities
    //   (or top-1 if only 1 template)
    // - keep a count of templates that strongly match the probe
    for (final _RecognizedStudent student in _roster) {
      if (student.embeddings.isEmpty) continue;
      final List<double> sims = <double>[];
      int hitCount = 0;
      for (final List<double> candidate in student.embeddings) {
        final double similarity = _cosineSimilarityNormalized(probe, candidate);
        sims.add(similarity);
        if (similarity >= _templateHitThreshold) {
          hitCount++;
        }
      }

      sims.sort((double a, double b) => b.compareTo(a));
      final double bestTemplate = sims.first;
      final double secondTemplate = sims.length > 1 ? sims[1] : -1;
      final double score = sims.length > 1
          ? ((bestTemplate + secondTemplate) / 2.0)
          : bestTemplate;

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

    if (bestScore < _similarityThreshold) {
      return _MatchResult(
        embedding: embedding,
        similarity: bestScore,
        secondBestSimilarity: secondBestScore,
        rejectionReason: 'below-threshold',
      );
    }

    final int templateCount = bestCandidate.embeddings.length;
    if (templateCount <= 1) {
      if (bestCandidateBestTemplate < _singleTemplateThreshold) {
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
        templateCount >= 6 ? 3 : _minTemplateHits,
      );
      if (bestCandidateHitCount < requiredHits) {
        return _MatchResult(
          embedding: embedding,
          similarity: bestScore,
          secondBestSimilarity: secondBestScore,
          rejectionReason: 'insufficient-template-agreement',
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
          : 'Session paused. Tap continue to record late students.';
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
    _sessionUiTimer?.cancel();
    _faceDetector?.close();
    _captureListController.dispose();
    _completeSessionDocument();
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
    final Widget preview = _buildPreviewPlaceholder();
    final bool showOvalGuide =
        !kIsWeb && (_cameraController?.value.isInitialized ?? false);
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
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? result) async {
        if (didPop) return;
        await _endSession();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Recognition session'),
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
            _SessionHeader(config: config, rosterCount: _roster.length),
            Expanded(
              child: ClaySurface(
                margin: const EdgeInsets.all(8),
                borderRadius: BorderRadius.circular(24),
                child: Stack(
                  children: <Widget>[
                    Positioned.fill(child: preview),
                    if (showOvalGuide)
                      const Positioned.fill(child: _OvalFaceGuideOverlay()),
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
                            color: theme.colorScheme.outlineVariant.withValues(
                              alpha: 0.35,
                            ),
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          child: Text(
                            _statusMessage ??
                                'Initializing session... hold on.',
                            style: theme.textTheme.bodyMedium,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
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
  });

  final String userId;
  final String displayName;
  final List<List<double>> embeddings;

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
