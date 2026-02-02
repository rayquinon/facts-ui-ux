import 'app_update_types.dart';

class AppUpdateService {
  static final AppUpdateService instance = AppUpdateService._();

  AppUpdateService._();

  Future<AppUpdateInfo?> checkForUpdate({Duration timeout = const Duration(seconds: 3)}) async {
    return null;
  }
}
