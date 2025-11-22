// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:async';
import 'dart:html' as html;
import 'dart:ui_web' as ui;

import 'package:flutter/material.dart';
import 'package:image/image.dart' as imglib;

class WebCameraFrame {
  WebCameraFrame({required this.image, required this.size});
  final imglib.Image image;
  final Size size;
}

class WebCameraService {
  WebCameraService();

  static const String _viewType = 'facts-webcam-view';

  html.VideoElement? _videoElement;
  html.CanvasElement? _canvasElement;
  html.MediaStream? _mediaStream;
  bool _viewRegistered = false;

  bool get isSupported => true;

  Future<void> initialize() async {
    if (_videoElement != null) return;

    _videoElement = html.VideoElement()
      ..autoplay = true
      ..muted = true
      ..style.objectFit = 'contain'
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.backgroundColor = '#000'
      ..style.transform = 'scaleX(-1)'
      ..style.transformOrigin = 'center';
    _canvasElement = html.CanvasElement();

    final mediaDevices = html.window.navigator.mediaDevices;
    if (mediaDevices == null) {
      throw UnsupportedError('Camera access is not available in this browser');
    }

    _mediaStream = await mediaDevices.getUserMedia({
      'video': {
        'facingMode': 'user',
        'width': {'ideal': 640},
        'height': {'ideal': 480},
      },
      'audio': false,
    });
    _videoElement!
      ..srcObject = _mediaStream
      ..setAttribute('playsinline', 'true');
    await _videoElement!.play();

    if (!_viewRegistered) {
      ui.platformViewRegistry.registerViewFactory(
        _viewType,
        (int viewId) => _videoElement!,
      );
      _viewRegistered = true;
    }
  }

  Widget buildPreview() {
    if (!_viewRegistered) {
      return const Center(child: CircularProgressIndicator());
    }
    return HtmlElementView(viewType: _viewType);
  }

  Future<WebCameraFrame?> captureFrame() async {
    final video = _videoElement;
    final canvas = _canvasElement;
    if (video == null || canvas == null) return null;
    final width = video.videoWidth;
    final height = video.videoHeight;
    if (width == 0 || height == 0) return null;

    canvas
      ..width = width
      ..height = height;
    final context = canvas.context2D;
    context.drawImageScaled(video, 0, 0, width.toDouble(), height.toDouble());
    final imageData = context.getImageData(0, 0, width, height);
    final data = imageData.data;

    final imglib.Image rgbImage = imglib.Image(width: width, height: height);
    int offset = 0;
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final int r = data[offset++];
        final int g = data[offset++];
        final int b = data[offset++];
        final int a = data[offset++];
        rgbImage.setPixelRgba(x, y, r, g, b, a);
      }
    }

    return WebCameraFrame(
      image: rgbImage,
      size: Size(width.toDouble(), height.toDouble()),
    );
  }

  void dispose() {
    _mediaStream?.getTracks().forEach((track) => track.stop());
    _mediaStream = null;
    _videoElement?.pause();
    _videoElement?.srcObject = null;
    _videoElement = null;
    _canvasElement = null;
  }
}
