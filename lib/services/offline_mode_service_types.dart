class OfflineModeSectionStatus {
  const OfflineModeSectionStatus({
    required this.sectionLabel,
    required this.isCached,
    this.studentCount,
    this.preparedAt,
    this.error,
  });

  final String sectionLabel;
  final bool isCached;
  final int? studentCount;
  final DateTime? preparedAt;
  final String? error;
}

class OfflineModeStatus {
  const OfflineModeStatus({
    required this.modelAvailable,
    required this.sectionStatuses,
  });

  final bool modelAvailable;
  final List<OfflineModeSectionStatus> sectionStatuses;

  bool get allSectionsCached =>
      sectionStatuses.isNotEmpty && sectionStatuses.every((s) => s.isCached);

  bool get isReady => modelAvailable && allSectionsCached;
}
