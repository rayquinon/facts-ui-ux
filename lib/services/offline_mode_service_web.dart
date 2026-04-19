import 'offline_mode_service_types.dart';

class OfflineModeService {
  Future<void> resetOfflineMode() async {
    throw UnsupportedError('Offline face scanning is not supported on web.');
  }

  Future<bool> isModelAvailable() async => false;

  Future<List<OfflineModeSectionStatus>> checkSectionsCached(
    List<String> sectionLabels,
  ) async {
    return sectionLabels
        .map(
          (label) => OfflineModeSectionStatus(
            sectionLabel: label.trim(),
            isCached: false,
            studentCount: null,
            preparedAt: null,
            error: 'Offline face scanning is not supported on web.',
          ),
        )
        .toList(growable: false);
  }

  Future<void> warmUpModel() async {
    throw UnsupportedError('Offline face scanning is not supported on web.');
  }

  Future<void> prepareSectionCache(String sectionLabel) async {
    throw UnsupportedError('Offline face scanning is not supported on web.');
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
