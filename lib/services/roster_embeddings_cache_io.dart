import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'roster_embeddings_cache.dart';

class _FileRosterEmbeddingsCache implements RosterEmbeddingsCache {
  const _FileRosterEmbeddingsCache();

  String _safeFileName(String key) {
    final String normalized = key.trim().toLowerCase();
    final String safe = normalized.replaceAll(RegExp(r'[^a-z0-9._-]+'), '_');
    return safe.isEmpty ? 'default' : safe;
  }

  Future<Directory> _cacheDir() async {
    final Directory base = await getApplicationSupportDirectory();
    final Directory dir = Directory('${base.path}${Platform.pathSeparator}roster_cache');
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  Future<File> _fileForKey(String key) async {
    final Directory dir = await _cacheDir();
    final String name = _safeFileName(key);
    return File('${dir.path}${Platform.pathSeparator}$name.json');
  }

  @override
  Future<String?> readJson({required String key}) async {
    try {
      final File file = await _fileForKey(key);
      if (!file.existsSync()) return null;
      return await file.readAsString();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> writeJson({required String key, required String json}) async {
    try {
      final File file = await _fileForKey(key);
      await file.writeAsString(json, flush: true);
    } catch (_) {
      // Best-effort only.
    }
  }
}

RosterEmbeddingsCache createRosterEmbeddingsCache() {
  return const _FileRosterEmbeddingsCache();
}
