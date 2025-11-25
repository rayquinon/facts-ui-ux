import 'dart:math' as math;

import 'package:image/image.dart' as imglib;

/// Configuration for adaptive brightness normalization.
class ImageNormalizationConfig {
  const ImageNormalizationConfig({
    this.enableClahe = true,
    this.claheTileSize = 8,
    this.claheClipFactor = 2.0,
    this.enableGammaCorrection = true,
    this.gamma = 0.9,
  }) : assert(claheTileSize > 0, 'CLAHE tile size must be positive'),
       assert(claheClipFactor > 0, 'CLAHE clip factor must be positive'),
       assert(gamma > 0, 'Gamma must be positive');

  final bool enableClahe;
  final int claheTileSize;
  final double claheClipFactor;
  final bool enableGammaCorrection;
  final double gamma;

  ImageNormalizationConfig copyWith({
    bool? enableClahe,
    int? claheTileSize,
    double? claheClipFactor,
    bool? enableGammaCorrection,
    double? gamma,
  }) {
    return ImageNormalizationConfig(
      enableClahe: enableClahe ?? this.enableClahe,
      claheTileSize: claheTileSize ?? this.claheTileSize,
      claheClipFactor: claheClipFactor ?? this.claheClipFactor,
      enableGammaCorrection:
          enableGammaCorrection ?? this.enableGammaCorrection,
      gamma: gamma ?? this.gamma,
    );
  }
}

/// Normalizes camera frames via CLAHE + gamma correction before inference.
class ImageNormalizationService {
  ImageNormalizationService({this.config = const ImageNormalizationConfig()});

  final ImageNormalizationConfig config;

  imglib.Image normalize(imglib.Image source) {
    if (source.width == 0 || source.height == 0) {
      return source;
    }
    final imglib.Image working = imglib.Image.from(source);
    if (config.enableClahe) {
      _applyClahe(working);
    }
    if (config.enableGammaCorrection) {
      _applyGamma(working);
    }
    return working;
  }

  void _applyClahe(imglib.Image image) {
    final int width = image.width;
    final int height = image.height;
    final int tileSize = config.claheTileSize;
    final List<int> luminance = List<int>.filled(width * height, 0);

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final imglib.Pixel pixel = image.getPixel(x, y);
        luminance[y * width + x] = _luminance(pixel);
      }
    }

    final List<int> equalized = _applyClaheToLuminance(
      luminance,
      width,
      height,
      tileSize,
    );

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final int idx = y * width + x;
        final imglib.Pixel pixel = image.getPixel(x, y);
        final double oldY = luminance[idx] / 255.0;
        final double newY = equalized[idx] / 255.0;
        final double ratio = oldY <= 0.0 || !oldY.isFinite
            ? newY
            : (newY / oldY).clamp(0.0, 4.0);
        final int r = _clampChannel(pixel.r * ratio);
        final int g = _clampChannel(pixel.g * ratio);
        final int b = _clampChannel(pixel.b * ratio);
        image.setPixelRgb(x, y, r, g, b);
      }
    }
  }

  List<int> _applyClaheToLuminance(
    List<int> luminance,
    int width,
    int height,
    int tileSize,
  ) {
    final int tilesX = ((width - 1) ~/ tileSize) + 1;
    final int tilesY = ((height - 1) ~/ tileSize) + 1;

    final List<List<List<int>>> luts = List<List<List<int>>>.generate(
      tilesY,
      (_) => List<List<int>>.generate(tilesX, (_) => List<int>.filled(256, 0)),
    );

    for (int ty = 0; ty < tilesY; ty++) {
      final int yStart = ty * tileSize;
      final int yEnd = math.min(yStart + tileSize, height);
      for (int tx = 0; tx < tilesX; tx++) {
        final int xStart = tx * tileSize;
        final int xEnd = math.min(xStart + tileSize, width);
        final int tileWidth = xEnd - xStart;
        final int tileHeight = yEnd - yStart;
        final int tilePixels = tileWidth * tileHeight;
        if (tilePixels <= 0) {
          continue;
        }
        final List<int> histogram = List<int>.filled(256, 0);
        for (int y = yStart; y < yEnd; y++) {
          final int rowOffset = y * width;
          for (int x = xStart; x < xEnd; x++) {
            histogram[luminance[rowOffset + x]]++;
          }
        }
        _clipHistogram(histogram, tilePixels);
        int cumulative = 0;
        final double scale = 255.0 / tilePixels;
        for (int i = 0; i < 256; i++) {
          cumulative += histogram[i];
          luts[ty][tx][i] = _roundToByte(cumulative * scale);
        }
      }
    }

    final List<int> output = List<int>.filled(width * height, 0);
    for (int y = 0; y < height; y++) {
      final int ty = math.min(y ~/ tileSize, tilesY - 1);
      final int ty1 = math.min(ty + 1, tilesY - 1);
      final double fy = tilesY == 1
          ? 0.0
          : ((y - ty * tileSize) / tileSize).clamp(0.0, 1.0);
      for (int x = 0; x < width; x++) {
        final int idx = y * width + x;
        final int value = luminance[idx];
        final int tx = math.min(x ~/ tileSize, tilesX - 1);
        final int tx1 = math.min(tx + 1, tilesX - 1);
        final double fx = tilesX == 1
            ? 0.0
            : ((x - tx * tileSize) / tileSize).clamp(0.0, 1.0);

        final double top = _lerp(luts[ty][tx][value], luts[ty][tx1][value], fx);
        final double bottom = _lerp(
          luts[ty1][tx][value],
          luts[ty1][tx1][value],
          fx,
        );
        output[idx] = _roundToByte(_lerp(top, bottom, fy));
      }
    }
    return output;
  }

  void _clipHistogram(List<int> histogram, int tilePixels) {
    final int clipLimit = math.max(
      1,
      (config.claheClipFactor * tilePixels / 256.0).round(),
    );
    int excess = 0;
    for (int i = 0; i < histogram.length; i++) {
      if (histogram[i] > clipLimit) {
        excess += histogram[i] - clipLimit;
        histogram[i] = clipLimit;
      }
    }
    final int increment = excess ~/ histogram.length;
    final int remainder = excess % histogram.length;
    for (int i = 0; i < histogram.length; i++) {
      histogram[i] += increment;
      if (i < remainder) {
        histogram[i]++;
      }
    }
  }

  void _applyGamma(imglib.Image image) {
    final double gamma = config.gamma;
    if ((gamma - 1.0).abs() < 1e-6) {
      return;
    }
    final double inverse = 1.0 / gamma;
    for (int y = 0; y < image.height; y++) {
      for (int x = 0; x < image.width; x++) {
        final imglib.Pixel pixel = image.getPixel(x, y);
        final int r = _clampChannel(math.pow(pixel.r / 255.0, inverse) * 255.0);
        final int g = _clampChannel(math.pow(pixel.g / 255.0, inverse) * 255.0);
        final int b = _clampChannel(math.pow(pixel.b / 255.0, inverse) * 255.0);
        image.setPixelRgb(x, y, r, g, b);
      }
    }
  }

  static int _luminance(imglib.Pixel pixel) {
    return _roundToByte(0.299 * pixel.r + 0.587 * pixel.g + 0.114 * pixel.b);
  }

  static double _lerp(num a, num b, double t) => a + (b - a) * t;

  static int _clampChannel(num value) {
    if (value <= 0) return 0;
    if (value >= 255) return 255;
    return value.round();
  }

  static int _roundToByte(num value) => _clampChannel(value);
}
