import 'dart:math' as math;
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as imglib;

/// Web-friendly fallback that produces a deterministic, lightweight embedding.
///
/// Without access to `dart:ffi` (and therefore ONNX Runtime) we approximate an
/// embedding by summarizing pixel intensities within the detected face region.
/// The output is intentionally simplistic but stable, which is preferable to
/// crashing when running on web builds.
class FaceEmbeddingService {
  FaceEmbeddingService._();

  static final FaceEmbeddingService instance = FaceEmbeddingService._();

  static const int _fallbackImageSize = 32;
  static const int _embeddingLength = 192;

  bool _initialized = false;

  Future<void> initialize() async {
    _initialized = true;
    debugPrint('FaceEmbeddingService (web) initialized with fallback mode.');
  }

  bool get isReady => _initialized;

  Future<List<double>> generateEmbedding(
    CameraImage image,
    Rect boundingBox,
  ) async {
    if (!_initialized) {
      await initialize();
    }

    final imglib.Image rgbImage = _convertYUV420ToImage(image);
    return _generateFromRgbImage(rgbImage, boundingBox);
  }

  Future<List<double>> generateEmbeddingFromImage(
    imglib.Image rgbImage,
    Rect boundingBox,
  ) async {
    if (!_initialized) {
      await initialize();
    }
    return _generateFromRgbImage(rgbImage, boundingBox);
  }

  List<double> _generateFromRgbImage(
    imglib.Image rgbImage,
    Rect boundingBox,
  ) {
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
      width: _fallbackImageSize,
      height: _fallbackImageSize,
      interpolation: imglib.Interpolation.average,
    );

    final List<double> buckets = List<double>.filled(_embeddingLength, 0);
    final List<int> counts = List<int>.filled(_embeddingLength, 0);

    for (int y = 0; y < resized.height; y++) {
      for (int x = 0; x < resized.width; x++) {
        final int bucketIndex = (y * resized.width + x) % _embeddingLength;
        final imglib.Pixel pixel = resized.getPixel(x, y);
        final double intensity =
            ((pixel.r + pixel.g + pixel.b) / 3.0 - 127.5) / 127.5;
        buckets[bucketIndex] += intensity.clamp(-1.0, 1.0);
        counts[bucketIndex]++;
      }
    }

    for (int i = 0; i < buckets.length; i++) {
      if (counts[i] > 0) {
        buckets[i] /= counts[i];
      }
    }

    return buckets;
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

    if (image.planes.length < 3) {
      // Some web implementations only expose a single plane (already RGB).
      final Plane plane = image.planes.first;
      int byteIndex = 0;
      for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
          final int r = plane.bytes[byteIndex++];
          final int g = byteIndex < plane.bytes.length
              ? plane.bytes[byteIndex++]
              : r;
          final int b = byteIndex < plane.bytes.length
              ? plane.bytes[byteIndex++]
              : r;
          converted.setPixelRgb(x, y, r, g, b);
        }
      }
      return converted;
    }

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
        final int g = (yValue - 0.344136 * (uValue - 128) -
                0.714136 * (vValue - 128))
            .round()
            .clamp(0, 255);
        final int b = (yValue + 1.772 * (uValue - 128)).round().clamp(0, 255);
        converted.setPixelRgb(x, y, r, g, b);
      }
    }
    return converted;
  }
}
