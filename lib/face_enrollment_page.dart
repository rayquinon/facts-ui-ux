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
import 'services/face_quality_exception.dart';

enum _OrientationPhase { front, left, right, up, down }

// width / height (head-like). Keep this moderately wide for portrait selfie
// framing without turning into a near-circle.
const double _kGuideAspectRatio = 0.78;
const double _kGuideCenterToleranceFactor =
    1.05; // strictness factor (smaller = stricter)

const Duration _kMinCaptureInterval = Duration(milliseconds: 700);

// MLKit's Face bounding box typically covers the face region (not full head),
// so size gating must be fairly tolerant to avoid breaking capture when the
// user moves closer/farther.
const double _kMinFaceAreaVsGuide = 0.10;
const double _kMaxFaceAreaVsGuide = 0.95;
const double _kMinFaceWidthVsGuide = 0.18;
const double _kMinFaceHeightVsGuide = 0.18;
const double _kMaxFaceWidthVsGuide = 1.15;
const double _kMaxFaceHeightVsGuide = 1.10;

Rect _computeGuideRect(Size size) {
  if (size.width <= 0 || size.height <= 0) {
    return Rect.zero;
  }

  // Size to the actual available preview bounds.
  // On portrait phones, the camera preview is often letterboxed, making
  // `minSide` much smaller than the screen. This tries to fill the preview.
  // Target a large guide, but avoid a full-screen oval.
  final double maxWidth = size.width * 0.88;
  final double maxHeight = size.height * 0.82;

  final double minWidth = size.width * 0.52;
  final double minHeight = size.height * 0.52;

  // Keep the aspect ratio intact while applying constraints.
  double height = maxHeight;
  double width = height * _kGuideAspectRatio;

  if (width > maxWidth) {
    width = maxWidth;
    height = width / _kGuideAspectRatio;
  }

  if (height > maxHeight) {
    height = maxHeight;
    width = height * _kGuideAspectRatio;
  }

  if (width < minWidth) {
    width = minWidth;
    height = width / _kGuideAspectRatio;
  }

  if (height < minHeight) {
    height = minHeight;
    width = height * _kGuideAspectRatio;
  }

  // Final safety clamp in case the min constraints force overshoot.
  if (width > maxWidth) {
    width = maxWidth;
    height = width / _kGuideAspectRatio;
  }
  if (height > maxHeight) {
    height = maxHeight;
    width = height * _kGuideAspectRatio;
  }

  return Rect.fromCenter(
    center: size.center(Offset.zero),
    width: width,
    height: height,
  );
}

enum _GuideMatch { ok, offCenter, tooSmall, tooLarge }

class FaceEnrollmentPage extends StatefulWidget {
  const FaceEnrollmentPage({super.key});

  static const String routeName = '/enroll-face';

  @override
  State<FaceEnrollmentPage> createState() => _FaceEnrollmentPageState();
}

class _FaceEnrollmentPageState extends State<FaceEnrollmentPage> {
  // Keep enrollment fast while still storing multiple templates for matching.
  // We capture 3 embeddings and store all 3 as `faceEmbeds`.
  static const int _capturesPerPhase = 3;
  static const int _storedEmbeddingsPerPhase = 3;
  static final List<_OrientationPhase> _phaseOrder = <_OrientationPhase>[
    _OrientationPhase.front,
    _OrientationPhase.left,
    _OrientationPhase.right,
    _OrientationPhase.up,
    _OrientationPhase.down,
  ];

  CameraController? _cameraController;
  FaceDetector? _faceDetector;
  final FaceEmbeddingService _embeddingService = FaceEmbeddingService.instance;
  // Face scanning is Android-only. Web/desktop builds should not start camera
  // pipelines here.
  bool _isProcessingFrame = false;
  bool _isSaving = false;
  bool _enrollmentStarted = false;
  bool _cameraReady = false;
  bool _cameraInitializing = false;
  bool _faceReadyForEnrollment = false;
  bool _enrollmentLocked = false;
  bool _enrollmentLockChecked = false;
  DateTime? _lastCaptureAt;
  Size? _lastPreviewContainerSize;
  int _lastRotationCompensation = 0;
  List<double>? _latestEmbedding;
  String? _statusMessage;
  int _currentPhaseIndex = 0;
  bool _autoSaveTriggered = false;
  final Map<_OrientationPhase, List<List<double>>> _phaseEmbeddings = {
    _OrientationPhase.front: <List<double>>[],
    _OrientationPhase.left: <List<double>>[],
    _OrientationPhase.right: <List<double>>[],
    _OrientationPhase.up: <List<double>>[],
    _OrientationPhase.down: <List<double>>[],
  };

  @override
  void initState() {
    super.initState();
    if (_faceScanningSupported) {
      _faceDetector = FaceDetector(
        options: FaceDetectorOptions(
          performanceMode: FaceDetectorMode.accurate,
          enableLandmarks: true,
          enableContours: false,
          enableTracking: false,
        ),
      );
    }
    _statusMessage = _faceScanningSupported
        ? 'Tap "Allow Camera" to preview before starting enrollment.'
        : 'Face enrollment is available only in the Android app.';

    _checkEnrollmentLock();
  }

  bool get _faceScanningSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> _checkEnrollmentLock() async {
    final User? user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      if (mounted) {
        setState(() => _enrollmentLockChecked = true);
      }
      return;
    }
    try {
      final DocumentSnapshot<Map<String, dynamic>> snapshot =
          await FirebaseFirestore.instance
              .collection('users')
              .doc(user.uid)
              .get();
      final Map<String, dynamic>? data = snapshot.data();
      final bool hasEmbeds =
          (data?['faceEmbeds'] is List &&
              (data!['faceEmbeds'] as List).isNotEmpty) ||
          (data?['faceEmbed'] is List &&
              (data!['faceEmbed'] as List).isNotEmpty);
      if (!mounted) return;
      if (hasEmbeds) {
        setState(() {
          _enrollmentLocked = true;
          _statusMessage =
              'Face enrollment already exists. Ask an admin to clear your face enrollment before re-enrolling.';
        });
      }
    } catch (_) {
      // If this check fails, don’t block enrollment.
    } finally {
      if (mounted) {
        setState(() => _enrollmentLockChecked = true);
      }
    }
  }

  Future<void> _initializePipeline() async {
    try {
      if (!_faceScanningSupported) {
        setState(() {
          _statusMessage =
              'Face enrollment is available only in the Android app.';
          _cameraReady = false;
          _faceReadyForEnrollment = false;
        });
        return;
      }
      await _embeddingService.initialize();
      await _initializeCamera();
      setState(() {
        _cameraReady = true;
        _faceReadyForEnrollment = false;
        _statusMessage =
            'Camera ready. Align your face, then tap "Start Enrollment".';
      });
    } catch (error) {
      setState(() {
        _statusMessage = 'Setup failed: $error';
        _enrollmentStarted = false;
        _cameraReady = false;
        _faceReadyForEnrollment = false;
      });
    }
  }

  Future<void> _startEnrollment() async {
    if (_enrollmentStarted || !_cameraReady) return;
    if (_enrollmentLocked) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Enrollment already exists. Ask an admin to clear it before re-enrolling.',
          ),
        ),
      );
      return;
    }
    final bool alignmentRequired = _faceDetector != null;
    if (alignmentRequired && !_faceReadyForEnrollment) {
      setState(() {
        _statusMessage =
            'Align your face inside the oval before starting enrollment.';
      });
      return;
    }

    final bool proceed = await _showEnrollmentOnboardingDialog();
    if (!proceed) return;
    if (!mounted) return;

    setState(() {
      _enrollmentStarted = true;
      _lastCaptureAt = null;
      for (final List<List<double>> bucket in _phaseEmbeddings.values) {
        bucket.clear();
      }
      _currentPhaseIndex = 0;
      _latestEmbedding = null;
      _statusMessage = _phaseInstruction(_currentPhase);
    });
  }

  Future<bool> _showEnrollmentOnboardingDialog() async {
    final bool? result = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('Before we start'),
          content: const Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('For best accuracy, please:'),
              SizedBox(height: 12),
              Text('• Remove accessories (glasses, hats, masks).'),
              SizedBox(height: 6),
              Text('• Stand in a well‑lit area (avoid strong backlight).'),
              SizedBox(height: 6),
              Text('• Hold still and keep your face inside the oval.'),
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Continue'),
            ),
          ],
        );
      },
    );
    return result ?? false;
  }

  Future<void> _handleAllowCamera() async {
    if (!_faceScanningSupported) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Face enrollment is available only in the Android app.',
          ),
        ),
      );
      return;
    }
    if (_cameraReady || _cameraInitializing) return;
    setState(() {
      _cameraInitializing = true;
      _statusMessage = 'Initializing camera and model...';
    });
    await _initializePipeline();
    if (!mounted) return;
    setState(() => _cameraInitializing = false);
  }

  Future<void> _initializeCamera() async {
    try {
      final List<CameraDescription> cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(
          () => _statusMessage =
              'No camera devices detected. Please connect a camera and retry.',
        );
        return;
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

      if (kIsWeb) {
        setState(() {
          _statusMessage =
              'Camera image streaming is unavailable on this platform. '
              'Please enroll using a mobile/desktop build with camera support.';
        });
        await controller.dispose();
        return;
      }

      await controller.startImageStream(_processCameraImage);
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _cameraController = controller);
    } on CameraException catch (error) {
      setState(
        () => _statusMessage =
            'Unable to initialize camera: ${error.description}',
      );
    }
  }

  Future<void> _processCameraImage(CameraImage image) async {
    if (_isProcessingFrame) return;
    final FaceDetector? detector = _faceDetector;
    if (detector == null) {
      return;
    }
    _isProcessingFrame = true;
    try {
      final InputImage inputImage = _buildInputImage(image);
      final List<Face> faces = await detector.processImage(inputImage);
      if (faces.isEmpty) {
        _updateFaceReadyState(false);
        if (_enrollmentStarted) {
          _updateNoFaceStatus();
        } else {
          _updateStatusWhenNotStarted(
            'No face detected. Make sure your face is well-lit and facing the camera.',
          );
        }
      } else {
        final Face face = faces.first;
        final Rect bbox = face.boundingBox;
        final Rect? previewRect = _currentPreviewRect(
          imageSize: Size(image.width.toDouble(), image.height.toDouble()),
        );
        final _GuideMatch guideMatch = previewRect == null
            ? _evaluateGuideMatch(
                bbox,
                Size(image.width.toDouble(), image.height.toDouble()),
              )
            : _evaluateGuideMatchInPreview(
                bbox,
                image,
                previewRect,
                rotationCompensation: _lastRotationCompensation,
              );
        // IMPORTANT: MLKit's boundingBox is typically the face region, not the full head.
        // The original size thresholds were tuned for a full-head guide and can be
        // too strict, preventing the user from ever starting enrollment.
        // For the Start button, require only that a face is centered (not off-center).
        final bool readyToStart = guideMatch != _GuideMatch.offCenter;
        final bool withinGuideForCapture = guideMatch == _GuideMatch.ok;

        if (_enrollmentStarted) {
          _updateFaceReadyState(withinGuideForCapture);
        } else {
          _updateFaceReadyState(readyToStart);
          if (guideMatch != _GuideMatch.ok) {
            _updateGuideStatus(guideMatch);
          } else {
            _updateStatusWhenNotStarted(
              'Face detected. Tap "Start Enrollment" to begin.',
            );
          }
        }
        if (_enrollmentStarted) {
          if (!withinGuideForCapture) {
            _updateGuideStatus(guideMatch);
          } else if (_embeddingService.isReady) {
            final DateTime now = DateTime.now();
            final DateTime? last = _lastCaptureAt;
            if (last != null && now.difference(last) < _kMinCaptureInterval) {
              return;
            }
            final Rect embeddingBbox = _mapMlKitBboxToRaw(
              bbox,
              rotationCompensation: _lastRotationCompensation,
              rawWidth: image.width.toDouble(),
              rawHeight: image.height.toDouble(),
            );
            final Offset? leftEye = _mapMlKitLandmarkToRaw(
              face.landmarks[FaceLandmarkType.leftEye],
              rotationCompensation: _lastRotationCompensation,
              rawWidth: image.width.toDouble(),
              rawHeight: image.height.toDouble(),
            );
            final Offset? rightEye = _mapMlKitLandmarkToRaw(
              face.landmarks[FaceLandmarkType.rightEye],
              rotationCompensation: _lastRotationCompensation,
              rawWidth: image.width.toDouble(),
              rawHeight: image.height.toDouble(),
            );
            final List<double> embedding = await _embeddingService
                .generateEmbeddingAligned(
                  image,
                  embeddingBbox,
                  leftEye: leftEye,
                  rightEye: rightEye,
                );
            await _recordEmbedding(embedding);
            _lastCaptureAt = now;
          }
        }
      }
    } on FaceQualityException catch (error) {
      if (!mounted) return;
      setState(() => _statusMessage = error.message);
    } catch (error) {
      debugPrint('Face processing error: $error');
    } finally {
      _isProcessingFrame = false;
    }
  }

  void _updateStatusWhenNotStarted(String message) {
    if (!mounted || _enrollmentStarted || !_cameraReady) return;
    setState(() => _statusMessage = message);
  }

  Rect? _currentPreviewRect({required Size imageSize}) {
    final Size? container = _lastPreviewContainerSize;
    final CameraController? controller = _cameraController;
    if (container == null ||
        controller == null ||
        !controller.value.isInitialized) {
      return null;
    }

    // CameraPreview behaves like a "contain" fit: it preserves aspect ratio and
    // may letterbox inside the available space. Compute the actual drawn rect.
    final double aspect = controller.value.aspectRatio;
    if (aspect <= 0 || container.width == 0 || container.height == 0) {
      return null;
    }

    double previewWidth;
    double previewHeight;
    if (container.width / container.height > aspect) {
      previewHeight = container.height;
      previewWidth = previewHeight * aspect;
    } else {
      previewWidth = container.width;
      previewHeight = previewWidth / aspect;
    }

    final Offset topLeft = Offset(
      (container.width - previewWidth) / 2,
      (container.height - previewHeight) / 2,
    );
    return topLeft & Size(previewWidth, previewHeight);
  }

  _GuideMatch _evaluateGuideMatchInPreview(
    Rect bbox,
    CameraImage image,
    Rect previewRect, {
    required int rotationCompensation,
  }) {
    // Map MLKit bbox (upright image coordinates) into the preview rect (screen coords).
    // When rotation is 90/270, MLKit returns bounding boxes in a coordinate
    // system where width/height are swapped versus the raw camera buffer.
    final double rawW = image.width.toDouble();
    final double rawH = image.height.toDouble();
    if (rawW <= 0 || rawH <= 0) return _GuideMatch.ok;

    final bool rotated =
        rotationCompensation == 90 || rotationCompensation == 270;
    final double imageW = rotated ? rawH : rawW;
    final double imageH = rotated ? rawW : rawH;

    Rect mapped = bbox;

    // Front camera preview is typically mirrored for a selfie experience.
    // Mirror horizontally so the bbox lines up with what the user sees.
    final bool isFront =
        _cameraController?.description.lensDirection ==
        CameraLensDirection.front;
    if (isFront) {
      mapped = Rect.fromLTRB(
        imageW - mapped.right,
        mapped.top,
        imageW - mapped.left,
        mapped.bottom,
      );
    }

    final double sx = previewRect.width / imageW;
    final double sy = previewRect.height / imageH;
    final Rect bboxScreen = Rect.fromLTRB(
      previewRect.left + (mapped.left * sx),
      previewRect.top + (mapped.top * sy),
      previewRect.left + (mapped.right * sx),
      previewRect.top + (mapped.bottom * sy),
    );

    final Size containerSize = _lastPreviewContainerSize ?? previewRect.size;
    // Use the full container for the guide sizing so the oval stays large on
    // tall portrait phones where the CameraPreview is letterboxed.
    final Rect guideRect = _computeGuideRect(containerSize);

    return _evaluateGuideMatchRects(bboxScreen, guideRect);
  }

  void _updateNoFaceStatus() {
    if (!mounted) return;
    setState(() {
      _latestEmbedding = null;
      _statusMessage =
          'No face detected. Keep ${_phaseLabel(_currentPhase)} and stay within the frame.';
    });
  }

  void _updateGuideStatus(_GuideMatch match) {
    if (!mounted) return;
    setState(() {
      _latestEmbedding = null;
      switch (match) {
        case _GuideMatch.offCenter:
          _statusMessage =
              'Center your face inside the oval before we can capture this step.';
          break;
        case _GuideMatch.tooSmall:
          _statusMessage = 'Move closer so your face fills more of the oval.';
          break;
        case _GuideMatch.tooLarge:
          _statusMessage = 'Move farther so your face fits inside the oval.';
          break;
        case _GuideMatch.ok:
          // No-op; the caller should not request a status update.
          break;
      }
    });
  }

  void _updateFaceReadyState(bool hasFaceInGuide) {
    if (!mounted || _faceReadyForEnrollment == hasFaceInGuide) {
      return;
    }
    setState(() => _faceReadyForEnrollment = hasFaceInGuide);
  }

  _GuideMatch _evaluateGuideMatch(Rect bbox, Size frameSize) {
    if (frameSize.width == 0 || frameSize.height == 0) return _GuideMatch.ok;

    final Rect guideRect = _computeGuideRect(frameSize);
    if (guideRect.width == 0 || guideRect.height == 0) return _GuideMatch.ok;

    return _evaluateGuideMatchRects(bbox, guideRect);
  }

  _GuideMatch _evaluateGuideMatchRects(Rect bbox, Rect guideRect) {
    // Strict center check using ellipse math.
    final Offset guideCenter = guideRect.center;
    final Offset boxCenter = bbox.center;
    final double a = guideRect.width / 2;
    final double b = guideRect.height / 2;
    final double denomX = a * _kGuideCenterToleranceFactor;
    final double denomY = b * _kGuideCenterToleranceFactor;
    if (denomX > 0 && denomY > 0) {
      final double nx = (boxCenter.dx - guideCenter.dx) / denomX;
      final double ny = (boxCenter.dy - guideCenter.dy) / denomY;
      if ((nx * nx) + (ny * ny) > 1) {
        return _GuideMatch.offCenter;
      }
    }

    // Size gating tuned for MLKit face boxes (more tolerant than a full-head guide).
    final double bboxWidth = bbox.width.abs();
    final double bboxHeight = bbox.height.abs();
    final double guideW = guideRect.width;
    final double guideH = guideRect.height;
    if (guideW <= 0 || guideH <= 0) return _GuideMatch.ok;

    final double bboxArea = bboxWidth * bboxHeight;
    final double guideArea = guideW * guideH;
    final double areaRatio = guideArea <= 0 ? 0 : (bboxArea / guideArea);

    final bool tooSmall =
        areaRatio < _kMinFaceAreaVsGuide ||
        bboxWidth < guideW * _kMinFaceWidthVsGuide ||
        bboxHeight < guideH * _kMinFaceHeightVsGuide;
    if (tooSmall) return _GuideMatch.tooSmall;

    final bool tooLarge =
        areaRatio > _kMaxFaceAreaVsGuide ||
        bboxWidth > guideW * _kMaxFaceWidthVsGuide ||
        bboxHeight > guideH * _kMaxFaceHeightVsGuide;
    if (tooLarge) return _GuideMatch.tooLarge;

    return _GuideMatch.ok;
  }

  Future<void> _recordEmbedding(List<double> embedding) async {
    final _OrientationPhase phase = _currentPhase;
    final List<List<double>> bucket = _phaseEmbeddings[phase]!;
    if (bucket.length >= _capturesPerPhase || !mounted) {
      return;
    }
    bucket.add(embedding);

    final int captured = bucket.length;
    if (captured < _capturesPerPhase) {
      if (!mounted) return;
      setState(() {
        final int remaining = _capturesPerPhase - captured;
        _statusMessage =
            '${_phaseLabel(phase)} capture $captured/$_capturesPerPhase. Hold steady for $remaining more.';
      });
      return;
    }

    // Phase complete.
    if (_currentPhaseIndex < _phaseOrder.length - 1) {
      final _OrientationPhase nextPhase = _phaseOrder[_currentPhaseIndex + 1];
      if (nextPhase != _OrientationPhase.front) {
        await _showPosePhaseOnboardingDialog(nextPhase);
        if (!mounted) return;
      }

      setState(() {
        _currentPhaseIndex++;
        _lastCaptureAt = null;
        _statusMessage =
            'Great! ${_phaseLabel(phase)} captures complete. ${_phaseInstruction(_currentPhase)}';
      });
      return;
    }

    // Final phase complete.
    if (!mounted) return;
    setState(() {
      _latestEmbedding = _averageAllEmbeddings();
      _statusMessage = 'Captures complete. Saving your profile...';
      _stopStreams();

      if (!_autoSaveTriggered) {
        _autoSaveTriggered = true;
        Future<void>.microtask(() async {
          if (!mounted) return;
          await _handleSaveEmbedding();
        });
      }
    });
  }

  Future<void> _showPosePhaseOnboardingDialog(_OrientationPhase phase) async {
    final String title = switch (phase) {
      _OrientationPhase.left => 'Next: Turn Left',
      _OrientationPhase.right => 'Next: Turn Right',
      _OrientationPhase.up => 'Next: Tilt Up',
      _OrientationPhase.down => 'Next: Tilt Down',
      _OrientationPhase.front => 'Next: Face Forward',
    };

    final String instruction = switch (phase) {
      _OrientationPhase.left =>
          'Turn your head slightly to the LEFT while keeping your face inside the oval.',
      _OrientationPhase.right =>
          'Turn your head slightly to the RIGHT while keeping your face inside the oval.',
      _OrientationPhase.up =>
          'Tilt your chin slightly UP (look a bit higher) while keeping your face inside the oval.',
      _OrientationPhase.down =>
          'Tilt your chin slightly DOWN (look a bit lower) while keeping your face inside the oval.',
      _OrientationPhase.front => 'Face forward and stay centered in the oval.',
    };

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(instruction),
              const SizedBox(height: 12),
              const Text('Tips for accuracy:'),
              const SizedBox(height: 8),
              const Text('• Keep eyes on the camera'),
              const SizedBox(height: 4),
              const Text('• Hold still for 3 quick captures'),
              const SizedBox(height: 4),
              const Text('• Avoid strong backlight'),
            ],
          ),
          actions: <Widget>[
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Continue'),
            ),
          ],
        );
      },
    );
  }

  List<double> _averageAllEmbeddings() {
    final List<List<double>> allVectors = _phaseEmbeddings.values
        .expand((List<List<double>> e) => e)
        .toList(growable: false);
    if (allVectors.isEmpty) {
      return <double>[];
    }
    final int length = allVectors.first.length;
    final List<double> sums = List<double>.filled(length, 0);
    for (final List<double> vector in allVectors) {
      for (int i = 0; i < length; i++) {
        sums[i] += vector[i];
      }
    }
    final double divisor = allVectors.length.toDouble();
    return sums.map((double value) => value / divisor).toList();
  }

  _OrientationPhase get _currentPhase => _phaseOrder[_currentPhaseIndex];

  bool get _isReadyToSave =>
      _phaseEmbeddings.values.every(
        (List<List<double>> bucket) => bucket.length >= _capturesPerPhase,
      ) &&
      (_latestEmbedding?.isNotEmpty ?? false);

  String _phaseLabel(_OrientationPhase phase) {
    switch (phase) {
      case _OrientationPhase.front:
        return 'Face forward';
      case _OrientationPhase.left:
        return 'Turn slightly left';
      case _OrientationPhase.right:
        return 'Turn slightly right';
      case _OrientationPhase.up:
        return 'Tilt slightly up';
      case _OrientationPhase.down:
        return 'Tilt slightly down';
    }
  }

  String _phaseInstruction(_OrientationPhase phase) {
    final int step = _phaseOrder.indexOf(phase) + 1;
    final String label = _phaseLabel(phase);
    return 'Step $step/${_phaseOrder.length}: $label and hold still while we capture $_capturesPerPhase images.';
  }

  void _stopStreams() {
    _cameraController?.stopImageStream();
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

    // Persist for bbox→preview mapping.
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

  Future<void> _handleSaveEmbedding() async {
    final List<double>? embedding = _latestEmbedding;
    final User? user = FirebaseAuth.instance.currentUser;
    if (embedding == null || user == null) return;

    if (_enrollmentLocked) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Enrollment already exists. Ask an admin to clear it before re-enrolling.',
          ),
        ),
      );
      return;
    }

    if (!_faceScanningSupported) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Face enrollment must be done in the Android app for recognition to work.',
          ),
        ),
      );
      return;
    }

    setState(() => _isSaving = true);
    try {
      final List<List<double>> selectedVectors =
          _selectRepresentativeEmbeddings(perPhase: _storedEmbeddingsPerPhase);

      // Firestore does not support nested arrays (List<List<num>>).
      // Store as an array of maps instead.
      final List<Map<String, dynamic>> embeddingsForStorage = selectedVectors
          .map((List<double> v) => <String, dynamic>{'v': v})
          .toList(growable: false);
      await FirebaseFirestore.instance.collection('users').doc(user.uid).set(<
        String,
        dynamic
      >{
        // Keep the averaged embedding for backward compatibility/quick matching.
        'faceEmbed': embedding,

        // Store multiple samples for robust matching.
        'faceEmbeds': embeddingsForStorage,
        'faceEmbedCount': embeddingsForStorage.length,
        'faceEmbedProvider': 'onnx_v1',
        'faceEmbedUpdatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Face enrolled successfully.')),
      );
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to save: $error')));
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  List<List<double>> _selectRepresentativeEmbeddings({required int perPhase}) {
    final List<List<double>> selected = <List<double>>[];
    for (final _OrientationPhase phase in _phaseOrder) {
      final List<List<double>> bucket =
          _phaseEmbeddings[phase] ?? <List<double>>[];
      if (bucket.isEmpty) {
        continue;
      }

      final List<int> indices = <int>[];
      if (perPhase <= 1 || bucket.length == 1) {
        indices.add(0);
      } else if (perPhase == 2) {
        indices.add(0);
        indices.add(bucket.length - 1);
      } else {
        indices.add(0);
        indices.add(bucket.length ~/ 2);
        indices.add(bucket.length - 1);
      }

      final Set<int> uniq = indices
          .where((int i) => i >= 0 && i < bucket.length)
          .toSet();
      for (final int i in uniq) {
        selected.add(List<double>.from(bucket[i], growable: false));
      }
    }
    return selected;
  }

  @override
  void dispose() {
    _cameraController?.stopImageStream();
    _cameraController?.dispose();
    _faceDetector?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_faceScanningSupported) {
      return Scaffold(
        appBar: AppBar(title: const Text('Enroll your face')),
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'Face enrollment is available only in the Android app.',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      );
    }

    final CameraController? controller = _cameraController;
    final Widget preview = controller == null
        ? Center(child: Text(_statusMessage ?? 'Preparing camera...'))
        : CameraPreview(controller);
    final bool hasLivePreview = controller != null;
    return Scaffold(
      appBar: AppBar(title: const Text('Enroll your face')),
      body: Column(
        children: <Widget>[
          Expanded(
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                _lastPreviewContainerSize = constraints.biggest;
                final Rect? previewRect = (controller != null)
                    ? _currentPreviewRect(
                        imageSize: controller.value.previewSize == null
                            ? const Size(0, 0)
                            : Size(
                                controller.value.previewSize!.width,
                                controller.value.previewSize!.height,
                              ),
                      )
                    : null;

                return Stack(
                  children: <Widget>[
                    Positioned.fill(child: preview),
                    if (hasLivePreview)
                      Positioned.fill(
                        child: _FaceGuideOverlay(
                          phaseLabel: _phaseLabel(_currentPhase),
                          phase: _currentPhase,
                          showDirectionArrow: _enrollmentStarted,
                          previewRect: previewRect,
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
          if (_statusMessage != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Card(
                elevation: 4,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(_statusMessage!, textAlign: TextAlign.center),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _buildPrimaryActionButton(),
                const SizedBox(height: 8),
                Text(
                  'Your facial embedding will be stored securely and used for attendance verification.',
                  style: Theme.of(context).textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPrimaryActionButton() {
    if (!_cameraReady) {
      return FilledButton.icon(
        onPressed: _cameraInitializing ? null : () => _handleAllowCamera(),
        icon: _cameraInitializing
            ? const SizedBox(
                height: 16,
                width: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.videocam),
        label: Text(
          _cameraInitializing ? 'Requesting camera...' : 'Allow Camera',
        ),
      );
    }
    if (_enrollmentLockChecked && _enrollmentLocked) {
      return FilledButton.icon(
        onPressed: null,
        icon: const Icon(Icons.lock_outline),
        label: const Text('Enrollment already exists'),
      );
    }
    if (!_enrollmentStarted) {
      final bool faceDetectionAvailable = _faceDetector != null;
      final bool canStart = !faceDetectionAvailable || _faceReadyForEnrollment;
      return FilledButton.icon(
        onPressed: canStart ? () => _startEnrollment() : null,
        icon: const Icon(Icons.play_arrow),
        label: Text(canStart ? 'Start Enrollment' : 'Align face to start'),
      );
    }
    return FilledButton.icon(
      onPressed: _isSaving || !_isReadyToSave
          ? null
          : () => _handleSaveEmbedding(),
      icon: _isSaving
          ? const SizedBox(
              height: 16,
              width: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.save_alt),
      label: Text(_isSaving ? 'Saving...' : 'Save & Continue'),
    );
  }
}

class _FaceGuideOverlay extends StatelessWidget {
  const _FaceGuideOverlay({
    required this.phaseLabel,
    required this.phase,
    required this.showDirectionArrow,
    required this.previewRect,
  });

  final String phaseLabel;
  final _OrientationPhase phase;
  final bool showDirectionArrow;
  final Rect? previewRect;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return IgnorePointer(
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: CustomPaint(
              painter: _FaceGuideMaskPainter(previewRect: previewRect),
            ),
          ),
          Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.only(top: 48),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 12,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        'Align your face inside the oval',
                        style: textTheme.titleSmall?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        phaseLabel,
                        style: textTheme.bodySmall?.copyWith(
                          color: Colors.white70,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      if (showDirectionArrow &&
                          (phase == _OrientationPhase.left ||
                              phase == _OrientationPhase.right))
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Icon(
                            phase == _OrientationPhase.left
                                ? Icons.arrow_back
                                : Icons.arrow_forward,
                            color: Colors.white,
                            size: 40,
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
    );
  }
}

class _FaceGuideMaskPainter extends CustomPainter {
  const _FaceGuideMaskPainter({required this.previewRect});

  final Rect? previewRect;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect bounds = Offset.zero & size;
    // Always size the guide to the full available area so it doesn't shrink
    // when the CameraPreview is letterboxed.
    final Rect guideRect = _computeGuideRect(size);

    final Path maskPath = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(bounds)
      ..addOval(guideRect);

    final Paint dimPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.6)
      ..style = PaintingStyle.fill;
    canvas.drawPath(maskPath, dimPaint);

    final Paint borderPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    canvas.drawOval(guideRect, borderPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
