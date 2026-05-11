class AttendanceOutboxService {
  AttendanceOutboxService._();

  static final AttendanceOutboxService instance = AttendanceOutboxService._();

  Future<int> pendingCountBestEffort() async {
    return 0;
  }

  Future<List<Map<String, Object?>>> pendingOperationsForSession(
      String sessionId,
      {bool fuzzy = false}) async {
    return <Map<String, Object?>>[];
  }

  Future<void> enqueueCapture({
    required String sessionId,
    required String captureId,
    required String capturedAtLocalIso,
    required String? matchUserId,
    required String? matchDisplayName,
    required double? confidence,
    required double? similarity,
    required int? inferenceDurationMs,
    required List<double> embedding,
    required String? attendanceStatus,
  }) async {
    // No-op on non-IO platforms.
  }

  Future<void> enqueueAttendeeUpsert({
    required String sessionId,
    required String studentId,
    required String displayName,
    required bool isFirstStatusForStudent,
    required String capturedAtLocalIso,
    required double? confidence,
    required String? status,
    required int? minutesLate,
    required int? minutesAbsent,
  }) async {
    // No-op on non-IO platforms.
  }

  Future<void> enqueueSessionLastCaptureAt({required String sessionId}) async {
    // No-op on non-IO platforms.
  }

  Future<void> enqueueSessionUpsert({
    required String sessionId,
    required String classId,
    required String subjectCode,
    required String subjectName,
    String? section,
    String? term,
    String? location,
    required int dayOfWeek,
    required int startHour,
    required int startMinute,
    required int endHour,
    required int endMinute,
    required String scheduleKey,
    required String dateKey,
    String? instructorId,
    String? instructorEmail,
    required String status,
    String? scheduledStartAtIso,
    String? scheduledEndAtIso,
  }) async {
    // No-op on non-IO platforms.
  }

  Future<void> enqueueSessionPointer({
    required String pointerId,
    required String sessionId,
    required String classId,
    String? instructorId,
    required String dateKey,
    required String scheduleKey,
    required int dayOfWeek,
    required int startHour,
    required int startMinute,
    required int endHour,
    required int endMinute,
    required String status,
    bool ended = false,
  }) async {
    // No-op on non-IO platforms.
  }

  Future<void> flushBestEffort() async {
    // No-op on non-IO platforms.
  }

  Future<List<Map<String, String>>> readOutboxFiles() async {
    return <Map<String, String>>[];
  }
}
