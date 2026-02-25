class AppUpdateInfo {
  const AppUpdateInfo({
    required this.currentBuildNumber,
    required this.currentVersion,
    required this.latestBuildNumber,
    required this.latestVersion,
    required this.apkUrl,
    required this.arm64Url,
    required this.androidPageUrl,
    this.apkUrlAlt,
    this.arm64UrlAlt,
    this.androidPageUrlAlt,
  });

  final int currentBuildNumber;
  final String currentVersion;

  final int latestBuildNumber;
  final String latestVersion;

  final String? apkUrl;
  final String? arm64Url;
  final String? androidPageUrl;

  final String? apkUrlAlt;
  final String? arm64UrlAlt;
  final String? androidPageUrlAlt;

  bool get updateAvailable => latestBuildNumber > currentBuildNumber;

  // Prefer the universal APK first. An arm64-only APK can be incompatible on
  // 32-bit devices, causing confusing "not compatible" install errors.
  String? get preferredUrl =>
      apkUrl ??
      arm64Url ??
      androidPageUrl ??
      apkUrlAlt ??
      arm64UrlAlt ??
      androidPageUrlAlt;
}
