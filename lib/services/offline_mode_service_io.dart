import 'dart:io';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'face_embedding_service.dart';
import 'offline_mode_service_types.dart';

class OfflineModeService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

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
            isCached: isPrepared,
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

    final Map<String, dynamic> markers = await _readMarkers();
    final Map<String, dynamic> sections =
        (markers[_sectionsRootKey()] as Map?)?.cast<String, dynamic>() ??
        <String, dynamic>{};
    sections[_sectionPreparedAtKey(label)] = <String, dynamic>{
      'preparedAt': DateTime.now().millisecondsSinceEpoch,
      'studentCount': snapshot.docs.length,
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
