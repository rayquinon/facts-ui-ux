import 'dart:io';

import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Downloads and caches model files from Firebase Storage under `models/`.
class ModelManager {
  ModelManager._();
  static final ModelManager instance = ModelManager._();

  final FirebaseStorage _storage = FirebaseStorage.instance;

  /// Returns a local file path for [modelName]. If missing, attempts to
  /// download from Firebase Storage path `models/<modelName>`. If download
  /// fails and an asset exists, write the asset to local cache as fallback.
  Future<File> getModelFile(String modelName) async {
    final Directory dir = await getApplicationDocumentsDirectory();
    final File local = File('${dir.path}/$modelName');
    if (await local.exists()) return local;

    // Try download from Firebase Storage
    try {
      final Reference ref = _storage.ref().child('models/$modelName');
      final DownloadTask task = ref.writeToFile(local);
      await task;
      if (await local.exists()) return local;
    } catch (e) {
      debugPrint('Model download failed: $e');
    }

    // Fallback: try to copy from packaged asset (useful for tests or local dev)
    try {
      final ByteData bytes = await rootBundle.load('assets/models/$modelName');
      await local.writeAsBytes(bytes.buffer.asUint8List());
      return local;
    } catch (e) {
      throw StateError('Could not obtain model $modelName: $e');
    }
  }
}
