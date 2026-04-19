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

  static const String _markerFileName = 'offline_mode_markers.json';

  Future<File> _markerFile() async {
    final Directory dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_markerFileName');
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
    const int batchSize = 8;

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

        bool hasEmbeddings = false;
        if (isPrepared) {
          try {
            final String cacheKey = _rosterCacheKeyForSection(sectionLabel);
            final String? jsonString = await _rosterCache.readJson(
              key: cacheKey,
            );
            if (jsonString != null && jsonString.trim().isNotEmpty) {
              final Object? decoded = jsonDecode(jsonString);
              if (decoded is Map) {
                final Object? rosterObj = decoded['roster'];
                if (rosterObj is List) {
                  final int rosterCount = rosterObj.length;
                  hasEmbeddings = (studentCount ?? 1) == 0 || rosterCount > 0;
                }
              }
            }
          } catch (_) {
            hasEmbeddings = false;
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
            isCached: isPrepared && hasEmbeddings,
            studentCount: studentCount,
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

    // Also download VPS embeddings and persist them to the local roster cache.
    // This is required for offline recognition (Firestore cache alone is not
    // enough).
    final Map<String, Object?> rosterPayload =
        await _downloadRosterEmbeddingsFromVps(snapshot.docs);
    final String cacheKey = _rosterCacheKeyForSection(label);
    await _rosterCache.writeJson(
      key: cacheKey,
      json: jsonEncode(rosterPayload),
    );

    final Map<String, dynamic> markers = await _readMarkers();
    final Map<String, dynamic> sections =
        (markers[_sectionsRootKey()] as Map?)?.cast<String, dynamic>() ??
        <String, dynamic>{};
    sections[_sectionPreparedAtKey(label)] = <String, dynamic>{
      'preparedAt': DateTime.now().millisecondsSinceEpoch,
      'studentCount': snapshot.docs.length,
      'embeddingsCachedAt': DateTime.now().millisecondsSinceEpoch,
      'embeddingsCount': (rosterPayload['roster'] is List)
          ? (rosterPayload['roster'] as List).length
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
