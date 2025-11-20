import 'dart:ffi' as ffi;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as imglib;
import 'package:onnxruntime/onnxruntime.dart';
import 'package:onnxruntime/src/bindings/onnxruntime_bindings_generated.dart'
    as bg;

/// Handles ONNX Runtime face embedding generation.
class FaceEmbeddingService {
  FaceEmbeddingService._();

  static final FaceEmbeddingService instance = FaceEmbeddingService._();

  static const String _modelAssetPath = 'assets/models/face_embedding.onnx';

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
      final ByteData rawModel = await rootBundle.load(_modelAssetPath);
      _session = OrtSession.fromBuffer(
        rawModel.buffer.asUint8List(),
        sessionOptions,
      );
      _inputName = _session!.inputNames.first;
      _inputShape = _readTensorShape(isInput: true);
      _outputShape = _readTensorShape(isInput: false);
      _channelsFirst =
          _inputShape.length == 4 && (_inputShape[1] == 3 || _inputShape[1] == 1);
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
      final List<OrtValue?> outputs =
          _session!.run(runOptions, {_inputName: inputTensor});
      try {
        final dynamic rawOutput = outputs.first?.value;
        final List<double> embedding =
            _flattenToDoubleList(rawOutput).take(_embeddingLength ?? 192).toList();
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

  Float32List _preprocessCameraImage(CameraImage cameraImage, Rect boundingBox) {
    if (_inputSize == null) {
      throw StateError('Embedding model is not initialized.');
    }
    final imglib.Image rgbImage = _convertYUV420ToImage(cameraImage);
    return _preprocessRgbImage(rgbImage, boundingBox);
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

    final int planeSize = _inputSize! * _inputSize!;
    final Float32List buffer = Float32List(planeSize * 3);
    if (_channelsFirst) {
      final int gOffset = planeSize;
      final int bOffset = planeSize * 2;
      for (int y = 0; y < _inputSize!; y++) {
        for (int x = 0; x < _inputSize!; x++) {
          final int idx = y * _inputSize! + x;
          final _NormalizedPixel pixel = _normalizePixel(resized.getPixel(x, y));
          buffer[idx] = pixel.r;
          buffer[gOffset + idx] = pixel.g;
          buffer[bOffset + idx] = pixel.b;
        }
      }
    } else {
      int offset = 0;
      for (int y = 0; y < _inputSize!; y++) {
        for (int x = 0; x < _inputSize!; x++) {
          final _NormalizedPixel pixel = _normalizePixel(resized.getPixel(x, y));
          buffer[offset++] = pixel.r;
          buffer[offset++] = pixel.g;
          buffer[offset++] = pixel.b;
        }
      }
    }
    return buffer;
  }

  int _resolveSpatialSize() {
    if (_inputShape.length < 3) {
      return _inputShape.lastWhere((value) => value > 0, orElse: () => 112);
    }
    final int heightIndex = _channelsFirst ? 2 : 1;
    final int widthIndex = _channelsFirst ? 3 : 2;
    final int height = heightIndex < _inputShape.length ? _inputShape[heightIndex] : -1;
    final int width = widthIndex < _inputShape.length ? _inputShape[widthIndex] : -1;
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

  List<int> _readTensorShape({required bool isInput, int index = 0}) {
    final ffi.Pointer<bg.OrtSession> sessionPtr =
        ffi.Pointer.fromAddress(_session!.address);
    final api = OrtEnv.instance.ortApiPtr.ref;
    final typeInfoPtr = calloc<ffi.Pointer<bg.OrtTypeInfo>>();
    final statusPtr = (isInput
            ? api.SessionGetInputTypeInfo
            : api.SessionGetOutputTypeInfo)
        .asFunction<bg.OrtStatusPtr Function(
            ffi.Pointer<bg.OrtSession>,
            int,
            ffi.Pointer<ffi.Pointer<bg.OrtTypeInfo>>)>()(
      sessionPtr,
      index,
      typeInfoPtr,
    );
    OrtStatus.checkOrtStatus(statusPtr);
    final tensorInfoPtrPtr = calloc<ffi.Pointer<bg.OrtTensorTypeAndShapeInfo>>();
    final castStatus = api.CastTypeInfoToTensorInfo.asFunction<
        bg.OrtStatusPtr Function(
            ffi.Pointer<bg.OrtTypeInfo>,
            ffi.Pointer<ffi.Pointer<bg.OrtTensorTypeAndShapeInfo>>)>()(
      typeInfoPtr.value,
      tensorInfoPtrPtr,
    );
    OrtStatus.checkOrtStatus(castStatus);
    final dimsCountPtr = calloc<ffi.Size>();
    final countStatus = api.GetDimensionsCount.asFunction<
        bg.OrtStatusPtr Function(
            ffi.Pointer<bg.OrtTensorTypeAndShapeInfo>,
            ffi.Pointer<ffi.Size>)>()(
      tensorInfoPtrPtr.value,
      dimsCountPtr,
    );
    OrtStatus.checkOrtStatus(countStatus);
    final int count = dimsCountPtr.value;
    final dimsPtr = calloc<ffi.Int64>(count);
    final dimsStatus = api.GetDimensions.asFunction<
        bg.OrtStatusPtr Function(
            ffi.Pointer<bg.OrtTensorTypeAndShapeInfo>,
            ffi.Pointer<ffi.Int64>,
            int)>()(
      tensorInfoPtrPtr.value,
      dimsPtr,
      count,
    );
    OrtStatus.checkOrtStatus(dimsStatus);
    final List<int> dims =
        List<int>.generate(count, (int i) => dimsPtr[i]);

    calloc.free(dimsPtr);
    calloc.free(dimsCountPtr);
    api.ReleaseTypeInfo
        .asFunction<void Function(ffi.Pointer<bg.OrtTypeInfo>)>()(
      typeInfoPtr.value,
    );
    calloc.free(tensorInfoPtrPtr);
    calloc.free(typeInfoPtr);
    return dims;
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
        final int g = (yValue - 0.344136 * (uValue - 128) - 0.714136 * (vValue - 128))
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
