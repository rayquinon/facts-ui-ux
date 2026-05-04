import 'app_update_types.dart';

class AppUpdateService {
  static final AppUpdateService instance = AppUpdateService._();

  AppUpdateService._();

  Future<AppUpdateInfo?> checkForUpdate({Duration timeout = const Duration(seconds: 3), bool force = false}) async {
    return null;
  }

  Future<void> downloadAndInstallUpdate(
    AppUpdateInfo update, {
    Duration timeout = const Duration(minutes: 3),
    void Function(int receivedBytes, int totalBytes)? onProgress,
  }) async {
    return;
  }
}

class AppUpdateException implements Exception {
  const AppUpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}

class AppUpdateNeedsInstallPermission extends AppUpdateException {
  const AppUpdateNeedsInstallPermission() : super('Install permission required.');
}
