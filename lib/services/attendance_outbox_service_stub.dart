class AttendanceOutboxService {
  AttendanceOutboxService._();

  static final AttendanceOutboxService instance = AttendanceOutboxService._();

  Future<int> pendingCountBestEffort() async {
    return 0;
  }

  Future<List<Map<String, Object?>>> pendingOperationsForSession(
      String sessionId) async {
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

  Future<void> flushBestEffort() async {
    // No-op on non-IO platforms.
  }
}
