import 'dart:typed_data';

import 'save_bytes_stub.dart'
    if (dart.library.html) 'save_bytes_web.dart'
    if (dart.library.io) 'save_bytes_io.dart';

/// Saves bytes to a file (mobile/desktop) or triggers a download (web).
///
/// Returns a file path when supported.
Future<String?> saveBytesAsFile(Uint8List bytes, String fileName) =>
    saveBytesAsFileImpl(bytes, fileName);
