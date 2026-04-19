import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

String _normalizeForFilenameSearch(String input) {
  final String lowered = input.trim().toLowerCase();
  if (lowered.isEmpty) return '';
  final String ascii = lowered.replaceAll(
    RegExp('[\u2010\u2011\u2012\u2013\u2014\u2212]'),
    '-',
  );
  return ascii.replaceAll(RegExp(r'[^a-z0-9]+'), '_');
}

DateTime? _tryParseCachedAtUtc(Map<String, Object?> decoded) {
  final Object? cachedAt = decoded['cachedAtUtc'];
  if (cachedAt is String) return DateTime.tryParse(cachedAt);
  return null;
}

int _rosterLength(Map<String, Object?> decoded) {
  final Object? rosterObj = decoded['roster'];
  if (rosterObj is List) return rosterObj.length;
  return 0;
}

Future<String?> findRosterCacheJsonForSectionBestEffortImpl({
  required String sectionLabel,
}) async {
  final String wanted = _normalizeForFilenameSearch(sectionLabel);
  if (wanted.isEmpty) return null;

  try {
    final Directory base = await getApplicationSupportDirectory();
    final Directory dir = Directory(
      '${base.path}${Platform.pathSeparator}roster_cache',
    );
    if (!await dir.exists()) return null;

    final List<FileSystemEntity> entries =
        await dir.list(followLinks: false).toList();

    String? bestJson;
    DateTime? bestTime;
    int bestRosterLen = 0;

    for (final FileSystemEntity entity in entries) {
      if (entity is! File) continue;
      final String name = entity.uri.pathSegments.isEmpty
          ? ''
          : entity.uri.pathSegments.last.toLowerCase();
      if (!name.endsWith('.json')) continue;
      if (!name.startsWith('roster_section_')) continue;

      // Name is already safe-normalized; compare on underscores.
      if (!name.contains(wanted)) continue;

      String raw;
      try {
        raw = await entity.readAsString();
      } catch (_) {
        continue;
      }
      if (raw.trim().isEmpty) continue;

      Map<String, Object?>? decoded;
      try {
        final Object? obj = jsonDecode(raw);
        if (obj is Map) {
          decoded = obj.map((k, v) => MapEntry(k.toString(), v));
        }
      } catch (_) {
        decoded = null;
      }
      if (decoded == null) continue;

      final int rosterLen = _rosterLength(decoded);
      final DateTime? cachedAt = _tryParseCachedAtUtc(decoded);

      // Prefer non-empty roster; then newest cachedAt.
      final bool betterRoster = rosterLen > bestRosterLen;
      final bool betterTime = cachedAt != null &&
          (bestTime == null || cachedAt.isAfter(bestTime));

      if (bestJson == null || betterRoster || (rosterLen == bestRosterLen && betterTime)) {
        bestJson = raw;
        bestTime = cachedAt;
        bestRosterLen = rosterLen;
      }
    }

    return bestJson;
  } catch (_) {
    return null;
  }
}
