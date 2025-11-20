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

class FaceEnrollmentPage extends StatefulWidget {
  const FaceEnrollmentPage({super.key});

  static const String routeName = '/enroll-face';

  @override
  State<FaceEnrollmentPage> createState() => _FaceEnrollmentPageState();
}

class _FaceEnrollmentPageState extends State<FaceEnrollmentPage> {
  CameraController? _cameraController;
  FaceDetector? _faceDetector;
  final FaceEmbeddingService _embeddingService = FaceEmbeddingService.instance;
  WebCameraService? _webCameraService;
  Timer? _webFrameTimer;
  bool _isProcessingFrame = false;
  bool _isSaving = false;
  List<double>? _latestEmbedding;
  String? _statusMessage;

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
    _initializePipeline();
  }

  Future<void> _initializePipeline() async {
    setState(() => _statusMessage = 'Initializing camera and model...');
    try {
      await _embeddingService.initialize();
      if (kIsWeb) {
        await _initializeWebCamera();
      } else {
        await _initializeCamera();
      }
      setState(() => _statusMessage = 'Align your face within the frame.');
    } catch (error) {
      setState(() => _statusMessage = 'Setup failed: $error');
    }
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
        setState(() => _statusMessage =
            'No camera devices detected. Please connect a camera and retry.');
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
      setState(() =>
          _statusMessage = 'Unable to initialize camera: ${error.description}');
    }
  }

  Future<void> _processCameraImage(CameraImage image) async {
    if (_isProcessingFrame || !_embeddingService.isReady) return;
    final FaceDetector? detector = _faceDetector;
    if (detector == null) {
      return;
    }
    _isProcessingFrame = true;
    try {
      final InputImage inputImage = _buildInputImage(image);
      final List<Face> faces = await detector.processImage(inputImage);
      if (faces.isEmpty) {
        if (mounted) {
          setState(() {
            _latestEmbedding = null;
            _statusMessage = 'No face detected. Please center your face.';
          });
        }
      } else {
        final Rect bbox = faces.first.boundingBox;
        final List<double> embedding =
            await _embeddingService.generateEmbedding(image, bbox);
        if (mounted) {
          setState(() {
            _latestEmbedding = embedding;
            _statusMessage =
                'Face captured. Tap "Save & Continue" to finish enrollment.';
          });
        }
      }
    } catch (error) {
      debugPrint('Face processing error: $error');
    } finally {
      _isProcessingFrame = false;
    }
  }

  Future<void> _processWebFrame() async {
    if (!kIsWeb || _isProcessingFrame || !_embeddingService.isReady) return;
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
      if (mounted) {
        setState(() {
          _latestEmbedding = embedding;
          _statusMessage =
              'Browser camera active. Tap "Save & Continue" when ready.';
        });
      }
    } catch (error) {
      debugPrint('Web frame processing error: $error');
    } finally {
      _isProcessingFrame = false;
    }
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
    final InputImageRotation rotation = InputImageRotationValue.fromRawValue(
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
      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .set(<String, dynamic>{'faceEmbed': embedding}, SetOptions(merge: true));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Face enrolled successfully.')),
      );
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to save: $error')),
      );
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
      preview = _webCameraService?.buildPreview() ??
          Center(child: Text(_statusMessage ?? 'Preparing browser camera...'));
    } else if (controller == null) {
      preview = Center(child: Text(_statusMessage ?? 'Preparing camera...'));
    } else {
      preview = CameraPreview(controller);
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Enroll your face')),
      body: Column(
        children: <Widget>[
          Expanded(
            child: Stack(
              children: <Widget>[
                Positioned.fill(child: preview),
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
                      FilledButton.icon(
                        onPressed: _isSaving || _latestEmbedding == null
                            ? null
                            : _handleSaveEmbedding,
                        icon: _isSaving
                            ? const SizedBox(
                                height: 16,
                                width: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.save_alt),
                        label: Text(_isSaving
                            ? 'Saving...'
                            : 'Save & Continue'),
                      ),
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
}
