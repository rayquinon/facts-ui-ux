import 'roster_embeddings_cache_stub.dart'
    if (dart.library.io) 'roster_embeddings_cache_io.dart';

abstract class RosterEmbeddingsCache {
  Future<void> writeJson({required String key, required String json});
  Future<String?> readJson({required String key});
}

RosterEmbeddingsCache getRosterEmbeddingsCache() => createRosterEmbeddingsCache();
