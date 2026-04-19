import 'roster_cache_locator_stub.dart'
    if (dart.library.io) 'roster_cache_locator_io.dart';

/// Best-effort helper for locating a cached roster payload on disk when the
/// caller does not know the exact cache key variant used.
Future<String?> findRosterCacheJsonForSectionBestEffort({
  required String sectionLabel,
}) => findRosterCacheJsonForSectionBestEffortImpl(sectionLabel: sectionLabel);
