import 'roster_embeddings_cache.dart';

class _NoopRosterEmbeddingsCache implements RosterEmbeddingsCache {
  const _NoopRosterEmbeddingsCache();

  @override
  Future<String?> readJson({required String key}) async {
    return null;
  }

  @override
  Future<void> writeJson({required String key, required String json}) async {
    // No-op (web/unsupported platform).
  }
}

RosterEmbeddingsCache createRosterEmbeddingsCache() {
  return const _NoopRosterEmbeddingsCache();
}
