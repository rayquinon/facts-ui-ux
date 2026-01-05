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

enum _OrientationPhase { front, left, right }

const double _kGuideWidthRatio = 0.3;
const double _kGuideHeightRatio = 0.7;
const double _kGuideCenterToleranceFactor =
    0.9; // slightly tighter than the oval edge
const double _kGuideSizeLowerBound = 0.45;
const double _kGuideSizeUpperBound = 1.6;

class FaceEnrollmentPage extends StatefulWidget {
  const FaceEnrollmentPage({super.key});

  static const String routeName = '/enroll-face';

  @override
  State<FaceEnrollmentPage> createState() => _FaceEnrollmentPageState();
}

class _FaceEnrollmentPageState extends State<FaceEnrollmentPage> {
  static const int _capturesPerPhase = 10;
  static final List<_OrientationPhase> _phaseOrder = _OrientationPhase.values;

  CameraController? _cameraController;
  FaceDetector? _faceDetector;
  final FaceEmbeddingService _embeddingService = FaceEmbeddingService.instance;
  WebCameraService? _webCameraService;
  Timer? _webFrameTimer;
  bool _isProcessingFrame = false;
  bool _isSaving = false;
  bool _enrollmentStarted = false;
  bool _cameraReady = false;
  bool _cameraInitializing = false;
  bool _faceReadyForEnrollment = kIsWeb;
  List<double>? _latestEmbedding;
  String? _statusMessage;
  int _currentPhaseIndex = 0;
  final Map<_OrientationPhase, List<List<double>>> _phaseEmbeddings = {
    _OrientationPhase.front: <List<double>>[],
    _OrientationPhase.left: <List<double>>[],
    _OrientationPhase.right: <List<double>>[],
  };

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
    _statusMessage =
        'Tap "Allow Camera" to preview before starting enrollment.';
  }

  Future<void> _initializePipeline() async {
    try {
      await _embeddingService.initialize();
      if (kIsWeb) {
        await _initializeWebCamera();
      } else {
        await _initializeCamera();
      }
      setState(() {
        _cameraReady = true;
        _faceReadyForEnrollment = kIsWeb;
        _statusMessage =
            'Camera ready. Align your face, then tap "Start Enrollment".';
      });
    } catch (error) {
      setState(() {
        _statusMessage = 'Setup failed: $error';
        _enrollmentStarted = false;
        _cameraReady = false;
        _faceReadyForEnrollment = kIsWeb;
      });
    }
  }

  Future<void> _startEnrollment() async {
    if (_enrollmentStarted || !_cameraReady) return;
    final bool alignmentRequired = _faceDetector != null;
    if (alignmentRequired && !_faceReadyForEnrollment) {
      setState(() {
        _statusMessage =
            'Align your face inside the oval before starting enrollment.';
      });
      return;
    }
    setState(() {
      _enrollmentStarted = true;
      for (final List<List<double>> bucket in _phaseEmbeddings.values) {
        bucket.clear();
      }
      _currentPhaseIndex = 0;
      _latestEmbedding = null;
      _statusMessage = _phaseInstruction(_currentPhase);
    });
  }

  Future<void> _handleAllowCamera() async {
    if (_cameraReady || _cameraInitializing) return;
    setState(() {
      _cameraInitializing = true;
      _statusMessage = 'Initializing camera and model...';
    });
    await _initializePipeline();
    if (!mounted) return;
    setState(() => _cameraInitializing = false);
  }

  Future<void> _initializeWebCamera() async {
    try {
      final service = WebCameraService();
      await service.initialize();
      _webCameraService = service;
      _webFrameTimer = Timer.periodic(
        const Duration(milliseconds: 900),
        (_) => _processWebFrame(),
      );
    } catch (error) {
      setState(() => _statusMessage = 'Web camera unavailable: $error');
    }
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
        }
      } else {
        final Rect bbox = faces.first.boundingBox;
        final Size frameSize = Size(
          image.width.toDouble(),
          image.height.toDouble(),
        );
        final bool withinGuide = _isBoundingBoxWithinGuide(bbox, frameSize);
        _updateFaceReadyState(withinGuide);
        if (_enrollmentStarted) {
          if (!withinGuide) {
            _updateMisalignedStatus();
          } else if (_embeddingService.isReady) {
            final List<double> embedding = await _embeddingService
                .generateEmbedding(image, bbox);
            _recordEmbedding(embedding);
          }
        }
      }
    } catch (error) {
      debugPrint('Face processing error: $error');
    } finally {
      _isProcessingFrame = false;
    }
  }

  Future<void> _processWebFrame() async {
    if (!kIsWeb || !_enrollmentStarted) return;
    if (_isProcessingFrame || !_embeddingService.isReady) return;
    _isProcessingFrame = true;
    try {
      final frame = await _webCameraService?.captureFrame();
      if (frame == null) return;
      final Size size = frame.size;
      final double cropSize = math.min(size.width, size.height) * 0.7;
      final Rect boundingBox = Rect.fromLTWH(
        (size.width - cropSize) / 2,
        (size.height - cropSize) / 2,
        cropSize,
        cropSize,
      );
      final List<double> embedding = await _embeddingService
          .generateEmbeddingFromImage(frame.image, boundingBox);
      _recordEmbedding(embedding);
    } catch (error) {
      debugPrint('Web frame processing error: $error');
    } finally {
      _isProcessingFrame = false;
    }
  }

  void _updateNoFaceStatus() {
    if (!mounted) return;
    setState(() {
      _latestEmbedding = null;
      _statusMessage =
          'No face detected. Keep ${_phaseLabel(_currentPhase)} and stay within the frame.';
    });
  }

  void _updateMisalignedStatus() {
    if (!mounted) return;
    setState(() {
      _latestEmbedding = null;
      _statusMessage =
          'Center your face inside the oval before we can capture this step.';
    });
  }

  void _updateFaceReadyState(bool hasFaceInGuide) {
    if (!mounted || _faceReadyForEnrollment == hasFaceInGuide) {
      return;
    }
    setState(() => _faceReadyForEnrollment = hasFaceInGuide);
  }

  bool _isBoundingBoxWithinGuide(Rect bbox, Size frameSize) {
    final double frameWidth = frameSize.width;
    final double frameHeight = frameSize.height;
    if (frameWidth == 0 || frameHeight == 0) {
      return true;
    }
    final Offset frameCenter = Offset(frameWidth / 2, frameHeight / 2);
    final Offset boxCenter = bbox.center;
    final double guideHalfWidth = frameWidth * _kGuideWidthRatio / 2;
    final double guideHalfHeight = frameHeight * _kGuideHeightRatio / 2;
    if (guideHalfWidth == 0 || guideHalfHeight == 0) {
      return true;
    }
    final double normalizedX =
        (boxCenter.dx - frameCenter.dx) /
        (guideHalfWidth * _kGuideCenterToleranceFactor);
    final double normalizedY =
        (boxCenter.dy - frameCenter.dy) /
        (guideHalfHeight * _kGuideCenterToleranceFactor);
    final double distanceFromCenter =
        normalizedX * normalizedX + normalizedY * normalizedY;
    if (distanceFromCenter > 1) {
      return false;
    }

    final double bboxWidth = bbox.width.abs();
    final double bboxHeight = bbox.height.abs();
    final double minWidth = guideHalfWidth * 2 * _kGuideSizeLowerBound;
    final double maxWidth = guideHalfWidth * 2 * _kGuideSizeUpperBound;
    final double minHeight = guideHalfHeight * 2 * _kGuideSizeLowerBound;
    final double maxHeight = guideHalfHeight * 2 * _kGuideSizeUpperBound;

    return bboxWidth >= minWidth &&
        bboxWidth <= maxWidth &&
        bboxHeight >= minHeight &&
        bboxHeight <= maxHeight;
  }

  void _recordEmbedding(List<double> embedding) {
    final _OrientationPhase phase = _currentPhase;
    final List<List<double>> bucket = _phaseEmbeddings[phase]!;
    if (bucket.length >= _capturesPerPhase || !mounted) {
      return;
    }
    bucket.add(embedding);
    setState(() {
      final int captured = bucket.length;
      if (captured >= _capturesPerPhase) {
        if (_currentPhaseIndex < _phaseOrder.length - 1) {
          _currentPhaseIndex++;
          _statusMessage =
              'Great! ${_phaseLabel(phase)} captures complete. ${_phaseInstruction(_currentPhase)}';
        } else {
          _latestEmbedding = _averageAllEmbeddings();
          _statusMessage =
              'All angles captured. Tap "Save & Continue" to store your profile.';
          _stopStreams();
        }
      } else {
        final int remaining = _capturesPerPhase - captured;
        _statusMessage =
            '${_phaseLabel(phase)} capture $captured/$_capturesPerPhase. Hold steady for $remaining more.';
      }
    });
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
    }
  }

  String _phaseInstruction(_OrientationPhase phase) {
    final int step = _phaseOrder.indexOf(phase) + 1;
    final String label = _phaseLabel(phase);
    return 'Step $step/${_phaseOrder.length}: $label and hold still while we capture $_capturesPerPhase images.';
  }

  void _stopStreams() {
    _cameraController?.stopImageStream();
    _webFrameTimer?.cancel();
  }

  InputImage _buildInputImage(CameraImage image) {
    final WriteBuffer allBytes = WriteBuffer();
    for (final Plane plane in image.planes) {
      allBytes.putUint8List(plane.bytes);
    }
    final Uint8List bytes = allBytes.done().buffer.asUint8List();
    final Size imageSize = Size(
      image.width.toDouble(),
      image.height.toDouble(),
    );
    final InputImageRotation rotation =
        InputImageRotationValue.fromRawValue(
          _cameraController?.description.sensorOrientation ?? 0,
        ) ??
        InputImageRotation.rotation0deg;
    final InputImageFormat format =
        InputImageFormatValue.fromRawValue(image.format.raw) ??
        InputImageFormat.nv21;
    final InputImageMetadata metadata = InputImageMetadata(
      size: imageSize,
      rotation: rotation,
      format: format,
      bytesPerRow: image.planes.first.bytesPerRow,
    );
    return InputImage.fromBytes(bytes: bytes, metadata: metadata);
  }

  Future<void> _handleSaveEmbedding() async {
    final List<double>? embedding = _latestEmbedding;
    final User? user = FirebaseAuth.instance.currentUser;
    if (embedding == null || user == null) return;

    setState(() => _isSaving = true);
    try {
      await FirebaseFirestore.instance.collection('users').doc(user.uid).set(
        <String, dynamic>{'faceEmbed': embedding},
        SetOptions(merge: true),
      );
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

  @override
  void dispose() {
    _cameraController?.stopImageStream();
    _cameraController?.dispose();
    _webFrameTimer?.cancel();
    _webCameraService?.dispose();
    _faceDetector?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final CameraController? controller = _cameraController;
    final bool isWeb = kIsWeb;
    Widget preview;
    if (isWeb) {
      preview =
          _webCameraService?.buildPreview() ??
          Center(child: Text(_statusMessage ?? 'Preparing browser camera...'));
    } else if (controller == null) {
      preview = Center(child: Text(_statusMessage ?? 'Preparing camera...'));
    } else {
      preview = CameraPreview(controller);
    }
    final bool hasLivePreview = isWeb
        ? _webCameraService != null
        : controller != null;
    return Scaffold(
      appBar: AppBar(title: const Text('Enroll your face')),
      body: Column(
        children: <Widget>[
          Expanded(
            child: Stack(
              children: <Widget>[
                Positioned.fill(child: preview),
                if (hasLivePreview)
                  Positioned.fill(
                    child: _FaceGuideOverlay(
                      phaseLabel: _phaseLabel(_currentPhase),
                    ),
                  ),
                if (_statusMessage != null)
                  Positioned(
                    left: 16,
                    right: 16,
                    bottom: 24,
                    child: Card(
                      elevation: 4,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          _statusMessage!,
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  ),
              ],
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
  const _FaceGuideOverlay({required this.phaseLabel});

  final String phaseLabel;

  @override
  Widget build(BuildContext context) {
    final TextTheme textTheme = Theme.of(context).textTheme;
    return IgnorePointer(
      child: Stack(
        children: <Widget>[
          const Positioned.fill(
            child: CustomPaint(painter: _FaceGuideMaskPainter()),
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
  const _FaceGuideMaskPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final Rect bounds = Offset.zero & size;
    final double ovalWidth = size.width * _kGuideWidthRatio;
    final double ovalHeight = size.height * _kGuideHeightRatio;
    final Rect ovalRect = Rect.fromCenter(
      center: size.center(Offset.zero),
      width: ovalWidth,
      height: ovalHeight,
    );

    final Path maskPath = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(bounds)
      ..addOval(ovalRect);

    final Paint dimPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.6)
      ..style = PaintingStyle.fill;
    canvas.drawPath(maskPath, dimPaint);

    final Paint borderPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    canvas.drawOval(ovalRect, borderPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
