import 'dart:io';

import 'package:image/image.dart' as img;

void main(List<String> args) {
  // Input logo may be wide (e.g., 1280x669). Android launcher icons expect a
  // square source. This script generates a padded square output.
  final String inputPath = args.isNotEmpty ? args.first : 'assets/logo.png';

  final File inputFile = File(inputPath);
  if (!inputFile.existsSync()) {
    stderr.writeln('Input image not found: $inputPath');
    exitCode = 2;
    return;
  }

  final img.Image? source = img.decodeImage(inputFile.readAsBytesSync());
  if (source == null) {
    stderr.writeln('Failed to decode image: $inputPath');
    exitCode = 3;
    return;
  }

  // 1024x1024 is a common high-res launcher icon source size.
  const int outSize = 1024;

  // Keep generous padding so it looks good in Android's circular/squircle masks.
  // Foreground max size ~70% of canvas.
  const double contentScale = 0.70;
  final int maxSide = (outSize * contentScale).round();

  final double scale = maxSide / (source.width > source.height ? source.width : source.height);
  final int resizedW = (source.width * scale).round();
  final int resizedH = (source.height * scale).round();

  final img.Image resized = img.copyResize(
    source,
    width: resizedW,
    height: resizedH,
    interpolation: img.Interpolation.cubic,
  );

  // 1) Adaptive foreground: transparent background.
  final img.Image foreground = img.Image(width: outSize, height: outSize);
  img.fill(foreground, color: img.ColorRgba8(0, 0, 0, 0));
  final int dx = ((outSize - resizedW) / 2).round();
  final int dy = ((outSize - resizedH) / 2).round();
  img.compositeImage(foreground, resized, dstX: dx, dstY: dy);

  // 2) Legacy square icon: white background + same centered content.
  final img.Image legacy = img.Image(width: outSize, height: outSize);
  img.fill(legacy, color: img.ColorRgba8(255, 255, 255, 255));
  img.compositeImage(legacy, resized, dstX: dx, dstY: dy);

  final Directory outDir = Directory('assets');
  outDir.createSync(recursive: true);

  final File fgOut = File('assets/logo_launcher_foreground.png');
  final File legacyOut = File('assets/logo_launcher.png');

  fgOut.writeAsBytesSync(img.encodePng(foreground, level: 9));
  legacyOut.writeAsBytesSync(img.encodePng(legacy, level: 9));

  stdout.writeln('Wrote: ${fgOut.path}');
  stdout.writeln('Wrote: ${legacyOut.path}');
}
