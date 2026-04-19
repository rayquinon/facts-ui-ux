import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'face_embedding_service.dart';
import 'offline_mode_service_types.dart';
import 'roster_embeddings_cache.dart';
import 'vps_embeddings_api_client.dart';

class OfflineModeService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final RosterEmbeddingsCache _rosterCache = getRosterEmbeddingsCache();

  static const Duration _cacheFreshnessWindow = Duration(hours: 18);

  static const String _markerFileName = 'offline_mode_markers.json';

  static const String _modelFileName = 'face_embedding.onnx';

  Future<File> _markerFile() async {
    final Directory dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_markerFileName');
  }

  Future<File> _modelFile() async {
    final Directory dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_modelFileName');
  }

  Future<Directory> _rosterCacheDir() async {
    final Directory base = await getApplicationSupportDirectory();
    return Directory('${base.path}${Platform.pathSeparator}roster_cache');
  }

  /// Hard reset for offline mode:
  /// - Deletes the local roster embeddings cache
  /// - Deletes offline preparation markers
  /// - Deletes the locally cached ONNX model file
  /// - Resets any in-memory ONNX session so the model truly reloads
  Future<void> resetOfflineMode() async {
    // 1) Drop in-memory session first (so it doesn't keep using old bytes).
    try {
      FaceEmbeddingService.instance.reset();
    } catch (_) {
      // Best-effort only.
    }

    // 2) Delete roster cache directory.
    try {
      final Directory dir = await _rosterCacheDir();
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (_) {
      // Best-effort only.
    }

    // 3) Delete markers.
    try {
      final File file = await _markerFile();
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // Best-effort only.
    }

    // 4) Delete local model file.
    try {
      final File model = await _modelFile();
      if (await model.exists()) {
        await model.delete();
      }
    } catch (_) {
      // Best-effort only.
    }
  }

  Future<Map<String, dynamic>> _readMarkers() async {
    try {
      final File file = await _markerFile();
      if (!await file.exists()) return <String, dynamic>{};
      final String raw = await file.readAsString();
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return decoded;
      return <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  Future<void> _writeMarkers(Map<String, dynamic> markers) async {
    final File file = await _markerFile();
    await file.writeAsString(jsonEncode(markers));
  }

  String _sanitizeKeyPart(String input) {
    final String sanitized = input.toLowerCase().replaceAll(
      RegExp(r'[^a-z0-9]+'),
      '_',
    );
    return sanitized.isEmpty ? 'unknown' : sanitized;
  }

  String _sectionPreparedAtKey(String sectionLabel) =>
      _sanitizeKeyPart(sectionLabel);

  String _sectionsRootKey() => 'sections';

  String _normalizeSectionForCacheKey(String sectionLabel) {
    final String section = sectionLabel.trim();
    return section.isEmpty
        ? 'all'
        : section.toLowerCase().replaceAll(RegExp(r'\s+'), '-');
  }

  String _rosterCacheKeyForSection(String sectionLabel) {
    final String normalized = _normalizeSectionForCacheKey(sectionLabel);
    return 'roster_section_$normalized';
  }

  static List<double> _l2NormalizeVector(List<double> v) {
    if (v.isEmpty) return <double>[];
    double sumSquares = 0;
    for (final double x in v) {
      sumSquares += x * x;
    }
    if (sumSquares <= 0) return <double>[];
    final double inv = 1.0 / math.sqrt(sumSquares);
    return v.map((double x) => x * inv).toList(growable: false);
  }

  static List<double> _averageVectors(List<List<double>> vectors) {
    if (vectors.isEmpty) return <double>[];
    final int length = vectors.first.length;
    if (length <= 0) return <double>[];
    final List<double> sums = List<double>.filled(length, 0);
    for (final List<double> v in vectors) {
      if (v.length != length) continue;
      for (int i = 0; i < length; i++) {
        sums[i] += v[i];
      }
    }
    final double divisor = vectors.length.toDouble();
    if (divisor <= 0) return <double>[];
    return sums.map((double value) => value / divisor).toList(growable: false);
  }

  static String _resolveDisplayName(Map<String, dynamic> data, String docId) {
    const List<String> candidateKeys = <String>[
      'displayName',
      'display_name',
      'Full Name',
      'fullName',
      'FullName',
      'full_name',
      'fullname',
      'name',
      'studentName',
      'student_name',
    ];
    for (final String key in candidateKeys) {
      final String? raw = (data[key] as String?)?.trim();
      if (raw != null && raw.isNotEmpty) {
        return raw;
      }
    }
    final int safeLength = math.min(6, docId.length);
    final String fallback = safeLength > 0
        ? docId.substring(0, safeLength).toUpperCase()
        : 'UNKNOWN';
    return 'Student $fallback';
  }

  Future<void> _tryBootstrapInstructorClaimOnce() async {
    try {
      await FirebaseFunctions.instance
          .httpsCallable('bootstrapInstructorClaim')
          .call(<String, dynamic>{});
      await FirebaseAuth.instance.currentUser?.getIdToken(true);
    } catch (_) {
      // Best-effort only.
    }
  }

  Future<Map<String, Object?>> _downloadRosterEmbeddingsFromVps(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) async {
    const VpsEmbeddingsApiClient client = VpsEmbeddingsApiClient();
    const int batchSize = 14;

    final List<Map<String, Object?>> roster = <Map<String, Object?>>[];
    int missing = 0;
    int failed = 0;
    int forbidden = 0;
    bool attemptedBootstrap = false;

    for (int i = 0; i < docs.length; i += batchSize) {
      final int end = math.min(i + batchSize, docs.length);
      final List<QueryDocumentSnapshot<Map<String, dynamic>>> batch = docs
          .sublist(i, end);

      final List<Map<String, Object?>?> results = await Future.wait(
        batch.map((QueryDocumentSnapshot<Map<String, dynamic>> doc) async {
          try {
            VpsEmbeddingsRecord? record;
            try {
              record = await client.getEmbeddingForUid(
                doc.id,
                forceRefreshToken: false,
              );
            } on VpsEmbeddingsApiException catch (e) {
              if (e.statusCode == 401 || e.statusCode == 403) {
                try {
                  record = await client.getEmbeddingForUid(
                    doc.id,
                    forceRefreshToken: true,
                  );
                } on VpsEmbeddingsApiException catch (e2) {
                  if (e2.statusCode == 403 && !attemptedBootstrap) {
                    attemptedBootstrap = true;
                    await _tryBootstrapInstructorClaimOnce();
                    record = await client.getEmbeddingForUid(
                      doc.id,
                      forceRefreshToken: true,
                    );
                  } else {
                    rethrow;
                  }
                }
              } else {
                rethrow;
              }
            }
            if (record == null) {
              missing++;
              return null;
            }

            final List<List<double>> rawTemplates = record.embeddings.isNotEmpty
                ? record.embeddings
                : <List<double>>[record.embedding];
            final List<List<double>> templates = rawTemplates
                .map(_l2NormalizeVector)
                .where((List<double> v) => v.isNotEmpty)
                .toList(growable: false);
            if (templates.isEmpty) {
              failed++;
              return null;
            }

            final List<double> centroidUnit = _l2NormalizeVector(
              _averageVectors(templates),
            );
            if (centroidUnit.isEmpty) {
              failed++;
              return null;
            }

            final String displayName = _resolveDisplayName(doc.data(), doc.id);
            return <String, Object?>{
              'userId': doc.id,
              'displayName': displayName,
              'embeddings': templates,
              'centroidUnit': centroidUnit,
            };
          } on TimeoutException {
            failed++;
            return null;
          } on VpsEmbeddingsApiException catch (e) {
            if (e.statusCode == 404) {
              missing++;
              return null;
            }
            if (e.statusCode == 401 || e.statusCode == 403) {
              forbidden++;
              return null;
            }
            failed++;
            return null;
          } catch (_) {
            failed++;
            return null;
          }
        }),
      );

      for (final Map<String, Object?>? entry in results) {
        if (entry != null) roster.add(entry);
      }
    }

    roster.sort((a, b) {
      final String aName = (a['displayName'] as String?)?.toLowerCase() ?? '';
      final String bName = (b['displayName'] as String?)?.toLowerCase() ?? '';
      return aName.compareTo(bName);
    });

    return <String, Object?>{
      'cachedAtUtc': DateTime.now().toUtc().toIso8601String(),
      'roster': roster,
      'missing': missing,
      'failed': failed,
      'forbidden': forbidden,
      'totalUsers': docs.length,
    };
  }

  Map<String, Object?>? _tryDecodeCachePayload(String? jsonString) {
    if (jsonString == null) return null;
    final String trimmed = jsonString.trim();
    if (trimmed.isEmpty) return null;
    try {
      final Object? decoded = jsonDecode(trimmed);
      if (decoded is Map) {
        return decoded.map((Object? key, Object? value) {
          return MapEntry<String, Object?>(key.toString(), value);
        });
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  DateTime? _tryParseCachedAtUtc(Map<String, Object?> payload) {
    final Object? cachedAt = payload['cachedAtUtc'];
    if (cachedAt is String) {
      return DateTime.tryParse(cachedAt);
    }
    return null;
  }

  Map<String, Map<String, Object?>> _indexRosterEntries(
    Map<String, Object?> payload,
  ) {
    final Object? rosterObj = payload['roster'];
    if (rosterObj is! List) return <String, Map<String, Object?>>{};
    final Map<String, Map<String, Object?>> indexed =
        <String, Map<String, Object?>>{};
    for (final Object? item in rosterObj) {
      if (item is! Map) continue;
      final Map<String, Object?> entry = item.map((Object? key, Object? value) {
        return MapEntry<String, Object?>(key.toString(), value);
      });
      final String userId = (entry['userId'] ?? '').toString().trim();
      if (userId.isEmpty) continue;
      indexed[userId] = entry;
    }
    return indexed;
  }

  Future<bool> isModelAvailable() async {
    // Prefer local cached file (works fully offline).
    try {
      final Directory dir = await getApplicationDocumentsDirectory();
      final File model = File('${dir.path}/face_embedding.onnx');
      if (await model.exists()) return true;
    } catch (_) {
      // Ignore and try asset check below.
    }

    // If bundled as an asset, the app can copy it to local storage on demand.
    try {
      await rootBundle.load('assets/models/face_embedding.onnx');
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> warmUpModel() async {
    await FaceEmbeddingService.instance.initialize();
    final Map<String, dynamic> markers = await _readMarkers();
    markers['modelPreparedAt'] = DateTime.now().millisecondsSinceEpoch;
    await _writeMarkers(markers);
  }

  Future<List<OfflineModeSectionStatus>> checkSectionsCached(
    List<String> sectionLabels,
  ) async {
    final Map<String, dynamic> markers = await _readMarkers();
    final Map<String, dynamic> sections =
        (markers[_sectionsRootKey()] as Map?)?.cast<String, dynamic>() ??
        <String, dynamic>{};
    final List<OfflineModeSectionStatus> out = <OfflineModeSectionStatus>[];
    for (final String raw in sectionLabels) {
      final String sectionLabel = raw.trim();
      if (sectionLabel.isEmpty) {
        out.add(
          const OfflineModeSectionStatus(
            sectionLabel: '(missing section)',
            isCached: false,
            error: 'Class is missing a section label.',
          ),
        );
        continue;
      }

      try {
        final String key = _sectionPreparedAtKey(sectionLabel);
        final Map<String, dynamic> entry =
            (sections[key] as Map?)?.cast<String, dynamic>() ??
            <String, dynamic>{};
        final int? preparedAtMs = entry['preparedAt'] as int?;
        final int? studentCount = entry['studentCount'] as int?;
        // We intentionally do NOT rely on "docs.isNotEmpty" here: a section may
        // legitimately have zero students, but we still consider it prepared.
        // The persisted marker indicates we successfully fetched this section
        // from the server at least once.
        final bool isPrepared = preparedAtMs != null;

        bool cacheExists = false;
        int? embeddingsCount;
        int? missingCount;
        int? failedCount;
        int? forbiddenCount;
        if (isPrepared) {
          try {
            final String cacheKey = _rosterCacheKeyForSection(sectionLabel);
            final String? jsonString = await _rosterCache.readJson(
              key: cacheKey,
            );
            if (jsonString != null && jsonString.trim().isNotEmpty) {
              final Object? decoded = jsonDecode(jsonString);
              if (decoded is Map) {
                cacheExists = true;
                final Object? rosterObj = decoded['roster'];
                if (rosterObj is List) {
                  embeddingsCount = rosterObj.length;
                }
                final Object? missingObj = decoded['missing'];
                final Object? failedObj = decoded['failed'];
                final Object? forbiddenObj = decoded['forbidden'];
                if (missingObj is num) missingCount = missingObj.toInt();
                if (failedObj is num) failedCount = failedObj.toInt();
                if (forbiddenObj is num) forbiddenCount = forbiddenObj.toInt();
              }
            }
          } catch (_) {
            cacheExists = false;
          }
        }

        // Best-effort cache read (mainly to surface unexpected cache errors).
        try {
          await _firestore
              .collection('users')
              .where('role', isEqualTo: 'student')
              .where('section', isEqualTo: sectionLabel)
              .limit(1)
              .get(const GetOptions(source: Source.cache));
        } catch (_) {
          // Ignore; we still rely on our preparation marker.
        }
        out.add(
          OfflineModeSectionStatus(
            sectionLabel: sectionLabel,
            isCached: isPrepared && cacheExists,
            studentCount: studentCount,
            embeddingsCount: embeddingsCount,
            missingCount: missingCount,
            failedCount: failedCount,
            forbiddenCount: forbiddenCount,
            preparedAt: preparedAtMs == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(preparedAtMs),
          ),
        );
      } catch (e) {
        out.add(
          OfflineModeSectionStatus(
            sectionLabel: sectionLabel,
            isCached: false,
            studentCount: null,
            preparedAt: null,
            error: e.toString(),
          ),
        );
      }
    }
    return out;
  }

  Future<void> prepareSectionCache(String sectionLabel) async {
    final String label = sectionLabel.trim();
    if (label.isEmpty) {
      throw ArgumentError('Section label is empty.');
    }

    // Force a server fetch so we know we are actually online and we populate
    // the local cache for later offline usage.
    final QuerySnapshot<Map<String, dynamic>> snapshot = await _firestore
        .collection('users')
        .where('role', isEqualTo: 'student')
        .where('section', isEqualTo: label)
        .get(const GetOptions(source: Source.server));

    final String cacheKey = _rosterCacheKeyForSection(label);

    // Fast path: if the section has no students, store an empty roster payload.
    if (snapshot.docs.isEmpty) {
      final Map<String, Object?> emptyPayload = <String, Object?>{
        'cachedAtUtc': DateTime.now().toUtc().toIso8601String(),
        'roster': <Object?>[],
        'missing': 0,
        'failed': 0,
        'forbidden': 0,
        'totalUsers': 0,
      };
      await _rosterCache.writeJson(
        key: cacheKey,
        json: jsonEncode(emptyPayload),
      );

      final Map<String, dynamic> markers = await _readMarkers();
      final Map<String, dynamic> sections =
          (markers[_sectionsRootKey()] as Map?)?.cast<String, dynamic>() ??
          <String, dynamic>{};
      sections[_sectionPreparedAtKey(label)] = <String, dynamic>{
        'preparedAt': DateTime.now().millisecondsSinceEpoch,
        'studentCount': 0,
        'embeddingsCachedAt': DateTime.now().millisecondsSinceEpoch,
        'embeddingsCount': 0,
      };
      markers[_sectionsRootKey()] = sections;
      await _writeMarkers(markers);
      return;
    }

    // Incremental prep: reuse cached embeddings when possible and only fetch
    // embeddings for new student IDs.
    final String? existingJson = await _rosterCache.readJson(key: cacheKey);
    final Map<String, Object?>? existingPayload = _tryDecodeCachePayload(
      existingJson,
    );
    final DateTime? existingCachedAtUtc = existingPayload == null
        ? null
        : _tryParseCachedAtUtc(existingPayload);
    final bool existingFresh =
        existingCachedAtUtc != null &&
        DateTime.now().toUtc().difference(existingCachedAtUtc) <
            _cacheFreshnessWindow;

    final Set<String> allowedIds = snapshot.docs
        .map((doc) => doc.id.trim())
        .where((id) => id.isNotEmpty)
        .toSet();

    final Map<String, Map<String, Object?>> existingById =
        existingPayload == null
        ? <String, Map<String, Object?>>{}
        : _indexRosterEntries(existingPayload);

    final List<QueryDocumentSnapshot<Map<String, dynamic>>> docsToFetch =
        snapshot.docs
            .where((doc) => !existingById.containsKey(doc.id))
            .toList(growable: false);

    Map<String, Object?> mergedPayload;
    if (docsToFetch.isEmpty && existingPayload != null && existingFresh) {
      // Nothing new to fetch and cache is still fresh.
      mergedPayload = existingPayload;
    } else {
      final Map<String, Object?> fetchedPayload = docsToFetch.isEmpty
          ? <String, Object?>{
              'cachedAtUtc': DateTime.now().toUtc().toIso8601String(),
              'roster': <Object?>[],
              'missing': 0,
              'failed': 0,
              'forbidden': 0,
              'totalUsers': 0,
            }
          : await _downloadRosterEmbeddingsFromVps(docsToFetch);

      final List<Map<String, Object?>> fetchedRoster = _indexRosterEntries(
        fetchedPayload,
      ).values.toList(growable: false);

      final List<Map<String, Object?>> keptExisting = existingById.entries
          .where((e) => allowedIds.contains(e.key))
          .map((e) => e.value)
          .toList(growable: false);

      final Map<String, Map<String, Object?>> mergedById =
          <String, Map<String, Object?>>{
            for (final Map<String, Object?> entry in keptExisting)
              (entry['userId'] ?? '').toString().trim(): entry,
          };
      for (final Map<String, Object?> entry in fetchedRoster) {
        final String uid = (entry['userId'] ?? '').toString().trim();
        if (uid.isEmpty) continue;
        mergedById[uid] = entry;
      }

      final List<Map<String, Object?>> mergedRoster =
          mergedById.values
              .where((entry) {
                final String uid = (entry['userId'] ?? '').toString().trim();
                return uid.isNotEmpty && allowedIds.contains(uid);
              })
              .toList(growable: false)
            ..sort((a, b) {
              final String aName =
                  (a['displayName'] as String?)?.toLowerCase() ?? '';
              final String bName =
                  (b['displayName'] as String?)?.toLowerCase() ?? '';
              return aName.compareTo(bName);
            });

      mergedPayload = <String, Object?>{
        'cachedAtUtc': DateTime.now().toUtc().toIso8601String(),
        'roster': mergedRoster,
        'missing': fetchedPayload['missing'] ?? 0,
        'failed': fetchedPayload['failed'] ?? 0,
        'forbidden': fetchedPayload['forbidden'] ?? 0,
        'totalUsers': snapshot.docs.length,
      };
    }

    await _rosterCache.writeJson(
      key: cacheKey,
      json: jsonEncode(mergedPayload),
    );

    final Map<String, dynamic> markers = await _readMarkers();
    final Map<String, dynamic> sections =
        (markers[_sectionsRootKey()] as Map?)?.cast<String, dynamic>() ??
        <String, dynamic>{};
    sections[_sectionPreparedAtKey(label)] = <String, dynamic>{
      'preparedAt': DateTime.now().millisecondsSinceEpoch,
      'studentCount': snapshot.docs.length,
      'embeddingsCachedAt': DateTime.now().millisecondsSinceEpoch,
      'embeddingsCount': (mergedPayload['roster'] is List)
          ? (mergedPayload['roster'] as List).length
          : null,
    };
    markers[_sectionsRootKey()] = sections;
    await _writeMarkers(markers);
  }

  Future<OfflineModeStatus> getStatusForSections(
    List<String> sectionLabels,
  ) async {
    final bool modelAvailable = await isModelAvailable();
    final List<OfflineModeSectionStatus> sectionStatuses =
        await checkSectionsCached(sectionLabels);
    return OfflineModeStatus(
      modelAvailable: modelAvailable,
      sectionStatuses: sectionStatuses,
    );
  }
}
