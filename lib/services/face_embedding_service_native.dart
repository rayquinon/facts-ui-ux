import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as imglib;
import 'package:onnxruntime/onnxruntime.dart';

import 'image_normalization_service.dart';
import 'model_manager.dart';
import 'dart:io';
import 'face_quality_exception.dart';

/// Handles ONNX Runtime face embedding generation.
class FaceEmbeddingService {
  FaceEmbeddingService._();

  static final FaceEmbeddingService instance = FaceEmbeddingService._();
  final ImageNormalizationService _imageNormalizer =
      ImageNormalizationService();

  OrtSession? _session;
  late String _inputName;
  late List<int> _inputShape;
  late List<int> _outputShape;
  bool _channelsFirst = false;
  int? _inputSize;
  int? _embeddingLength;

  /// Initializes the ONNX Runtime session lazily.
  Future<void> initialize() async {
    if (_session != null) return;

    OrtSessionOptions? sessionOptions;
    try {
      OrtEnv.instance.init();
      sessionOptions = OrtSessionOptions()
        ..setIntraOpNumThreads(2)
        ..setInterOpNumThreads(2);
      final File modelFile = await ModelManager.instance.getModelFile(
        'face_embedding.onnx',
      );
      final Uint8List rawBytes = await modelFile.readAsBytes();
      _session = OrtSession.fromBuffer(rawBytes, sessionOptions);
      _inputName = _session!.inputNames.first;
      // Use the known face-embedding model tensor shapes. This avoids relying
      // on package-private onnxruntime bindings (lib/src) just to read shapes.
      _inputShape = const <int>[1, 3, 112, 112];
      _outputShape = const <int>[1, 192];
      _channelsFirst = true;
      _inputSize = _resolveSpatialSize();
      _embeddingLength = _resolveEmbeddingLength();
    } catch (error, stackTrace) {
      debugPrint('Failed to initialize ONNX model: $error\n$stackTrace');
      _session?.release();
      _session = null;
      rethrow;
    } finally {
      sessionOptions?.release();
    }
  }

  bool get isReady => _session != null;

  /// Generates a face embedding for the detected region inside [image].
  Future<List<double>> generateEmbedding(
    CameraImage image,
    Rect boundingBox,
  ) async {
    if (_session == null) {
      await initialize();
    }
    final Float32List inputBuffer = _preprocessCameraImage(image, boundingBox);
    return _runModel(inputBuffer);
  }

  /// Generates a face embedding for the detected region inside [image], with
  /// optional eye-based alignment and basic quality gating.
  ///
  /// The eye coordinates must be in the *raw* [CameraImage] coordinate space
  /// (same as [boundingBox]).
  Future<List<double>> generateEmbeddingAligned(
    CameraImage image,
    Rect boundingBox, {
    Offset? leftEye,
    Offset? rightEye,
  }) async {
    if (_session == null) {
      await initialize();
    }
    final Float32List inputBuffer = _preprocessCameraImageAligned(
      image,
      boundingBox,
      leftEye: leftEye,
      rightEye: rightEye,
    );
    return _runModel(inputBuffer);
  }

  /// Generates a face embedding from an RGB [imglib.Image] and bounding box.
  Future<List<double>> generateEmbeddingFromImage(
    imglib.Image rgbImage,
    Rect boundingBox,
  ) async {
    if (_session == null) {
      await initialize();
    }
    final Float32List inputBuffer = _preprocessRgbImage(rgbImage, boundingBox);
    return _runModel(inputBuffer);
  }

  Future<List<double>> _runModel(Float32List inputBuffer) async {
    final OrtValueTensor inputTensor = OrtValueTensor.createTensorWithDataList(
      inputBuffer,
      _inputShape,
    );
    final OrtRunOptions runOptions = OrtRunOptions();
    try {
      final List<OrtValue?> outputs = _session!.run(runOptions, {
        _inputName: inputTensor,
      });
      try {
        final dynamic rawOutput = outputs.first?.value;
        final List<double> embedding = _flattenToDoubleList(
          rawOutput,
        ).take(_embeddingLength ?? 192).toList();
        return embedding;
      } finally {
        for (final OrtValue? value in outputs) {
          value?.release();
        }
      }
    } finally {
      inputTensor.release();
      runOptions.release();
    }
  }

  Float32List _preprocessCameraImage(
    CameraImage cameraImage,
    Rect boundingBox,
  ) {
    if (_inputSize == null) {
      throw StateError('Embedding model is not initialized.');
    }
    final imglib.Image rgbImage = _convertYUV420ToImage(cameraImage);
    return _preprocessRgbImage(rgbImage, boundingBox);
  }

  Float32List _preprocessCameraImageAligned(
    CameraImage cameraImage,
    Rect boundingBox, {
    required Offset? leftEye,
    required Offset? rightEye,
  }) {
    if (_inputSize == null) {
      throw StateError('Embedding model is not initialized.');
    }
    final imglib.Image rgbImage = _convertYUV420ToImage(cameraImage);
    return _preprocessRgbImageAligned(
      rgbImage,
      boundingBox,
      leftEye: leftEye,
      rightEye: rightEye,
    );
  }

  Float32List _preprocessRgbImage(imglib.Image rgbImage, Rect boundingBox) {
    final math.Rectangle<int> cropRect = _boundingBoxToRect(
      boundingBox,
      imageWidth: rgbImage.width,
      imageHeight: rgbImage.height,
    );
    final imglib.Image cropped = imglib.copyCrop(
      rgbImage,
      x: cropRect.left,
      y: cropRect.top,
      width: cropRect.width,
      height: cropRect.height,
    );
    final imglib.Image resized = imglib.copyResize(
      cropped,
      width: _inputSize!,
      height: _inputSize!,
      interpolation: imglib.Interpolation.cubic,
    );
    final imglib.Image processed = _imageNormalizer.normalize(resized);

    final int planeSize = _inputSize! * _inputSize!;
    final Float32List buffer = Float32List(planeSize * 3);
    if (_channelsFirst) {
      final int gOffset = planeSize;
      final int bOffset = planeSize * 2;
      for (int y = 0; y < _inputSize!; y++) {
        for (int x = 0; x < _inputSize!; x++) {
          final int idx = y * _inputSize! + x;
          final _NormalizedPixel pixel = _normalizePixel(
            processed.getPixel(x, y),
          );
          buffer[idx] = pixel.r;
          buffer[gOffset + idx] = pixel.g;
          buffer[bOffset + idx] = pixel.b;
        }
      }
    } else {
      int offset = 0;
      for (int y = 0; y < _inputSize!; y++) {
        for (int x = 0; x < _inputSize!; x++) {
          final _NormalizedPixel pixel = _normalizePixel(
            processed.getPixel(x, y),
          );
          buffer[offset++] = pixel.r;
          buffer[offset++] = pixel.g;
          buffer[offset++] = pixel.b;
        }
      }
    }
    return buffer;
  }

  Float32List _preprocessRgbImageAligned(
    imglib.Image rgbImage,
    Rect boundingBox, {
    required Offset? leftEye,
    required Offset? rightEye,
  }) {
    // Default: bbox crop with a small margin.
    final Offset faceCenter = boundingBox.center;
    final double baseSize = math.max(
      boundingBox.width.abs(),
      boundingBox.height.abs(),
    );
    double cropSize = baseSize.isFinite && baseSize > 0 ? baseSize * 1.35 : 0;

    imglib.Image working = rgbImage;
    Offset cropCenter = faceCenter;

    if (leftEye != null && rightEye != null) {
      final double dx = rightEye.dx - leftEye.dx;
      final double dy = rightEye.dy - leftEye.dy;
      final double eyeDist = math.sqrt(dx * dx + dy * dy);

      if (eyeDist.isFinite && eyeDist > 2) {
        final double angle = math.atan2(dy, dx);
        final double angleDeg = -angle * 180.0 / math.pi;
        final Offset eyeMid = Offset(
          (leftEye.dx + rightEye.dx) / 2.0,
          (leftEye.dy + rightEye.dy) / 2.0,
        );

        // Translate so eye midpoint is at canvas center, rotate, then crop.
        final int w = rgbImage.width;
        final int h = rgbImage.height;
        final Offset canvasCenter = Offset(w / 2.0, h / 2.0);
        final int shiftX = (canvasCenter.dx - eyeMid.dx).round();
        final int shiftY = (canvasCenter.dy - eyeMid.dy).round();
        final imglib.Image canvas = imglib.Image(width: w, height: h);
        imglib.compositeImage(canvas, rgbImage, dstX: shiftX, dstY: shiftY);
        working = imglib.copyRotate(
          canvas,
          angle: angleDeg,
          interpolation: imglib.Interpolation.cubic,
        );

        // Rotate the face-center offset about the eye midpoint.
        final Offset offsetToFaceCenter = faceCenter - eyeMid;
        final double cosA = math.cos(-angle);
        final double sinA = math.sin(-angle);
        final Offset rotatedOffset = Offset(
          offsetToFaceCenter.dx * cosA - offsetToFaceCenter.dy * sinA,
          offsetToFaceCenter.dx * sinA + offsetToFaceCenter.dy * cosA,
        );
        cropCenter = canvasCenter + rotatedOffset;

        // Use eye distance as a stabilizer for crop size.
        cropSize = math.max(cropSize, eyeDist * 2.6);
      }
    }

    if (!cropSize.isFinite || cropSize <= 1) {
      cropSize =
          math.min(rgbImage.width.toDouble(), rgbImage.height.toDouble()) * 0.6;
    }

    final Rect square = Rect.fromCenter(
      center: cropCenter,
      width: cropSize,
      height: cropSize,
    );
    final math.Rectangle<int> cropRect = _boundingBoxToRect(
      square,
      imageWidth: working.width,
      imageHeight: working.height,
    );
    final imglib.Image cropped = imglib.copyCrop(
      working,
      x: cropRect.left,
      y: cropRect.top,
      width: cropRect.width,
      height: cropRect.height,
    );
    final imglib.Image resized = imglib.copyResize(
      cropped,
      width: _inputSize!,
      height: _inputSize!,
      interpolation: imglib.Interpolation.cubic,
    );

    _throwIfLowQuality(resized);

    final imglib.Image processed = _imageNormalizer.normalize(resized);

    final int planeSize = _inputSize! * _inputSize!;
    final Float32List buffer = Float32List(planeSize * 3);
    if (_channelsFirst) {
      final int gOffset = planeSize;
      final int bOffset = planeSize * 2;
      for (int y = 0; y < _inputSize!; y++) {
        for (int x = 0; x < _inputSize!; x++) {
          final int idx = y * _inputSize! + x;
          final _NormalizedPixel pixel = _normalizePixel(
            processed.getPixel(x, y),
          );
          buffer[idx] = pixel.r;
          buffer[gOffset + idx] = pixel.g;
          buffer[bOffset + idx] = pixel.b;
        }
      }
    } else {
      int offset = 0;
      for (int y = 0; y < _inputSize!; y++) {
        for (int x = 0; x < _inputSize!; x++) {
          final _NormalizedPixel pixel = _normalizePixel(
            processed.getPixel(x, y),
          );
          buffer[offset++] = pixel.r;
          buffer[offset++] = pixel.g;
          buffer[offset++] = pixel.b;
        }
      }
    }
    return buffer;
  }

  void _throwIfLowQuality(imglib.Image face112) {
    // Very lightweight quality gate to reduce false positives.
    // These thresholds are intentionally lenient.
    final _QualityStats stats = _computeQuality(face112);
    if (stats.meanLuma < 35) {
      throw FaceQualityException('Too dark. Improve lighting and try again.');
    }
    if (stats.meanLuma > 235) {
      throw FaceQualityException(
        'Too bright. Reduce glare/overexposure and retry.',
      );
    }
    if (stats.sharpness < 6.0) {
      throw FaceQualityException('Too blurry. Hold still and move closer.');
    }
  }

  _QualityStats _computeQuality(imglib.Image image) {
    // Sample every other pixel to keep it cheap.
    double sum = 0;
    int count = 0;
    for (int y = 0; y < image.height; y += 2) {
      for (int x = 0; x < image.width; x += 2) {
        final imglib.Pixel p = image.getPixel(x, y);
        // ITU-R BT.601 luma approx.
        final double luma = 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
        sum += luma;
        count++;
      }
    }
    final double meanLuma = count > 0 ? sum / count : 0;

    // Mean absolute Laplacian (cheap sharpness proxy).
    double lapSum = 0;
    int lapCount = 0;
    int lumAt(int x, int y) {
      final imglib.Pixel p = image.getPixel(x, y);
      return (0.299 * p.r + 0.587 * p.g + 0.114 * p.b).round();
    }

    for (int y = 1; y < image.height - 1; y += 2) {
      for (int x = 1; x < image.width - 1; x += 2) {
        final int c = lumAt(x, y);
        final int lap =
            -4 * c +
            lumAt(x - 1, y) +
            lumAt(x + 1, y) +
            lumAt(x, y - 1) +
            lumAt(x, y + 1);
        lapSum += lap.abs();
        lapCount++;
      }
    }
    final double sharpness = lapCount > 0 ? lapSum / lapCount : 0;
    return _QualityStats(meanLuma: meanLuma, sharpness: sharpness);
  }

  int _resolveSpatialSize() {
    if (_inputShape.length < 3) {
      return _inputShape.lastWhere((value) => value > 0, orElse: () => 112);
    }
    final int heightIndex = _channelsFirst ? 2 : 1;
    final int widthIndex = _channelsFirst ? 3 : 2;
    final int height = heightIndex < _inputShape.length
        ? _inputShape[heightIndex]
        : -1;
    final int width = widthIndex < _inputShape.length
        ? _inputShape[widthIndex]
        : -1;
    if (height > 0) return height;
    if (width > 0) return width;
    return 112;
  }

  int _resolveEmbeddingLength() {
    if (_outputShape.isEmpty) {
      return 192;
    }
    final Iterable<int> dims = _outputShape.length == 1
        ? _outputShape
        : _outputShape.skip(1); // drop batch dim when present
    final int length = dims.fold<int>(1, (value, element) {
      final int positive = element > 0 ? element : 1;
      return value * positive;
    });
    return length;
  }

  static _NormalizedPixel _normalizePixel(imglib.Pixel pixel) {
    return _NormalizedPixel(
      (pixel.r - 127.5) / 127.5,
      (pixel.g - 127.5) / 127.5,
      (pixel.b - 127.5) / 127.5,
    );
  }

  static math.Rectangle<int> _boundingBoxToRect(
    Rect bbox, {
    required int imageWidth,
    required int imageHeight,
  }) {
    final int left = math.max(bbox.left.round(), 0);
    final int top = math.max(bbox.top.round(), 0);
    final int right = math.min(bbox.right.round(), imageWidth);
    final int bottom = math.min(bbox.bottom.round(), imageHeight);
    return math.Rectangle<int>(
      left,
      top,
      math.max(right - left, 1),
      math.max(bottom - top, 1),
    );
  }

  static imglib.Image _convertYUV420ToImage(CameraImage image) {
    final int width = image.width;
    final int height = image.height;
    final imglib.Image converted = imglib.Image(width: width, height: height);
    final Plane yPlane = image.planes[0];
    final Plane uPlane = image.planes[1];
    final Plane vPlane = image.planes[2];
    final int uvRowStride = uPlane.bytesPerRow;
    final int uvPixelStride = uPlane.bytesPerPixel ?? 1;

    for (int y = 0; y < height; y++) {
      final int uvRow = uvRowStride * (y >> 1);
      for (int x = 0; x < width; x++) {
        final int uvIndex = uvRow + (x >> 1) * uvPixelStride;
        final int yValue = yPlane.bytes[y * yPlane.bytesPerRow + x];
        final int uValue = uPlane.bytes[uvIndex];
        final int vValue = vPlane.bytes[uvIndex];
        final int r = (yValue + 1.402 * (vValue - 128)).round().clamp(0, 255);
        final int g =
            (yValue - 0.344136 * (uValue - 128) - 0.714136 * (vValue - 128))
                .round()
                .clamp(0, 255);
        final int b = (yValue + 1.772 * (uValue - 128)).round().clamp(0, 255);
        converted.setPixelRgb(x, y, r, g, b);
      }
    }
    return converted;
  }

  static List<double> _flattenToDoubleList(dynamic value) {
    if (value is double) {
      return <double>[value];
    }
    if (value is num) {
      return <double>[value.toDouble()];
    }
    if (value is List) {
      final List<double> result = <double>[];
      for (final dynamic element in value) {
        result.addAll(_flattenToDoubleList(element));
      }
      return result;
    }
    throw StateError('Unsupported ONNX output type: ${value.runtimeType}');
  }
}

class _NormalizedPixel {
  const _NormalizedPixel(this.r, this.g, this.b);
  final double r;
  final double g;
  final double b;
}

class _QualityStats {
  const _QualityStats({required this.meanLuma, required this.sharpness});

  final double meanLuma;
  final double sharpness;
}
