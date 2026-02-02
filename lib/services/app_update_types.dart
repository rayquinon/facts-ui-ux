class AppUpdateInfo {
  const AppUpdateInfo({
    required this.currentBuildNumber,
    required this.currentVersion,
    required this.latestBuildNumber,
    required this.latestVersion,
    required this.apkUrl,
    required this.arm64Url,
    required this.androidPageUrl,
  });

  final int currentBuildNumber;
  final String currentVersion;

  final int latestBuildNumber;
  final String latestVersion;

  final String? apkUrl;
  final String? arm64Url;
  final String? androidPageUrl;

  bool get updateAvailable => latestBuildNumber > currentBuildNumber;

  String? get preferredUrl => arm64Url ?? apkUrl ?? androidPageUrl;
}
