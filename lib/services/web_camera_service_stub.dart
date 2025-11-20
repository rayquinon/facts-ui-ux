import 'package:flutter/widgets.dart';
import 'package:image/image.dart' as imglib;

class WebCameraFrame {
  const WebCameraFrame({required this.image, required this.size});
  final imglib.Image image;
  final Size size;
}

class WebCameraService {
  WebCameraService();

  bool get isSupported => false;

  Future<void> initialize() async {
    throw UnsupportedError('WebCameraService is only available on Flutter web');
  }

  Widget buildPreview() {
    return const SizedBox.shrink();
  }

  Future<WebCameraFrame?> captureFrame() async {
    return null;
  }

  void dispose() {}
}
