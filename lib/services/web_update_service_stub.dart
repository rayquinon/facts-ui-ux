class WebUpdateCheck {
  const WebUpdateCheck({
    required this.supported,
    this.registered,
    this.updateAvailable,
    this.error,
  });

  final bool supported;
  final bool? registered;
  final bool? updateAvailable;
  final String? error;
}

class WebUpdateService {
  WebUpdateService._();

  static final WebUpdateService instance = WebUpdateService._();

  Future<WebUpdateCheck> checkForUpdates({bool verbose = false}) async {
    return const WebUpdateCheck(supported: false);
  }
}
