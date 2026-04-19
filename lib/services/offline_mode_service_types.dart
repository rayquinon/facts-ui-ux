class OfflineModeSectionStatus {
  const OfflineModeSectionStatus({
    required this.sectionLabel,
    required this.isCached,
    this.studentCount,
    this.embeddingsCount,
    this.missingCount,
    this.failedCount,
    this.forbiddenCount,
    this.preparedAt,
    this.error,
  });

  final String sectionLabel;
  /// Whether the section cache exists locally (roster payload saved).
  final bool isCached;
  final int? studentCount;
  /// Number of students with embeddings available offline (roster entries).
  final int? embeddingsCount;
  final int? missingCount;
  final int? failedCount;
  final int? forbiddenCount;
  final DateTime? preparedAt;
  final String? error;

  bool get hasEmbeddings {
    final int students = studentCount ?? 0;
    if (students == 0) return true;
    return (embeddingsCount ?? 0) > 0;
  }
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

    bool get allSectionsEmbeddingsReady =>
      sectionStatuses.isNotEmpty &&
      sectionStatuses.every((s) => s.isCached && s.hasEmbeddings);

  bool get isReady => modelAvailable && allSectionsEmbeddingsReady;
}
