class AppUpdateInfo {
  const AppUpdateInfo({
    required this.currentBuildNumber,
    required this.currentVersion,
    required this.latestBuildNumber,
    required this.latestVersion,
    required this.apkUrl,
    required this.arm64Url,
    required this.armeabiV7aUrl,
    required this.x86_64Url,
    required this.androidPageUrl,
    this.apkUrlAlt,
    this.arm64UrlAlt,
    this.armeabiV7aUrlAlt,
    this.x86_64UrlAlt,
    this.androidPageUrlAlt,
    this.latestBuildNumberEffective,
    this.preferredUrlOverride,
  });

  final int currentBuildNumber;
  final String currentVersion;

  final int latestBuildNumber;
  final String latestVersion;

  final String? apkUrl;
  final String? arm64Url;
    final String? armeabiV7aUrl;
    final String? x86_64Url;
  final String? androidPageUrl;

  final String? apkUrlAlt;
  final String? arm64UrlAlt;
    final String? armeabiV7aUrlAlt;
    final String? x86_64UrlAlt;
  final String? androidPageUrlAlt;

    // When distributing split-per-ABI APKs, Android may assign different
    // versionCodes per ABI. This field allows the update service to provide an
    // ABI-adjusted build number for correct comparisons.
    final int? latestBuildNumberEffective;

    // Allows the update service to direct users to the best APK URL for their
    // device (for example, a specific ABI build).
    final String? preferredUrlOverride;

    int get effectiveLatestBuildNumber =>
      latestBuildNumberEffective ?? latestBuildNumber;

    String get effectiveLatestLabel => latestVersion.isEmpty
      ? 'build $effectiveLatestBuildNumber'
      : '$latestVersion+$effectiveLatestBuildNumber';

    bool get updateAvailable => effectiveLatestBuildNumber > currentBuildNumber;

  // Prefer the universal APK first. An arm64-only APK can be incompatible on
  // 32-bit devices, causing confusing "not compatible" install errors.
    String? get preferredUrl =>
      preferredUrlOverride ??
      apkUrl ??
      arm64Url ??
      armeabiV7aUrl ??
      x86_64Url ??
      androidPageUrl ??
      apkUrlAlt ??
      arm64UrlAlt ??
      armeabiV7aUrlAlt ??
      x86_64UrlAlt ??
      androidPageUrlAlt;
}
