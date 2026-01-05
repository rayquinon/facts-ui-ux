import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';
import 'dart:ui_web' as ui;

import 'package:flutter/material.dart';
import 'package:image/image.dart' as imglib;
import 'package:web/web.dart' as web;

class WebCameraFrame {
  WebCameraFrame({required this.image, required this.size});
  final imglib.Image image;
  final Size size;
}

class WebCameraService {
  WebCameraService() : _viewType = 'facts-webcam-view-${_instanceCounter++}';

  static int _instanceCounter = 0;

  final String _viewType;

  web.HTMLVideoElement? _videoElement;
  web.HTMLCanvasElement? _canvasElement;
  web.MediaStream? _mediaStream;
  bool _viewRegistered = false;

  bool get isSupported => true;

  Future<void> initialize() async {
    if (_videoElement != null) return;

    _videoElement = web.HTMLVideoElement()
      ..autoplay = true
      ..muted = true
      ..style.objectFit = 'contain'
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.backgroundColor = '#000'
      ..style.transform = 'scaleX(-1)'
      ..style.transformOrigin = 'center';
    _canvasElement = web.HTMLCanvasElement();

    final web.MediaDevices mediaDevices = web.window.navigator.mediaDevices;

    final JSAny videoConstraints = <String, Object?>{
      'facingMode': 'user',
      'width': <String, Object?>{'ideal': 640},
      'height': <String, Object?>{'ideal': 480},
    }.jsify() as JSAny;

    final web.MediaStreamConstraints constraints = web.MediaStreamConstraints(
      video: videoConstraints,
      audio: false.toJS,
    );

    _mediaStream = await mediaDevices.getUserMedia(constraints).toDart;
    _videoElement!
      ..srcObject = _mediaStream
      ..setAttribute('playsinline', 'true');
    await _videoElement!.play().toDart;

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
    final web.CanvasRenderingContext2D context = canvas.context2D;
    context.drawImage(video, 0, 0, width.toDouble(), height.toDouble());
    final web.ImageData imageData = context.getImageData(0, 0, width, height);
    final Uint8ClampedList data = imageData.data.toDart;

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
    final web.MediaStream? stream = _mediaStream;
    if (stream != null) {
      for (final web.MediaStreamTrack track in stream.getTracks().toDart) {
        track.stop();
      }
    }
    _mediaStream = null;
    _videoElement?.pause();
    _videoElement?.srcObject = null;
    _videoElement = null;
    _canvasElement = null;
  }
}
