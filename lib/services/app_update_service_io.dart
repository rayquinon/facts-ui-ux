import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';

import 'app_update_types.dart';

class AppUpdateService {
  static final AppUpdateService instance = AppUpdateService._();

  AppUpdateService._();

  // Keep this as a plain Hosting file to avoid Firestore/Remote Config costs.
  static const List<String> _manifestUrls = <String>[
    // Custom domain (preferred).
    'https://facts.shiro.codes/downloads/version.json',
    // Default Firebase Hosting domain (fallback).
    'https://simple-distributed-database.web.app/downloads/version.json',
  ];

  Future<AppUpdateInfo?> checkForUpdate({Duration timeout = const Duration(seconds: 3)}) async {
    final PackageInfo info = await PackageInfo.fromPlatform();
    final int currentBuild = int.tryParse(info.buildNumber) ?? 0;
    final String currentVersion = info.version;

    final Map<String, dynamic>? manifest = await _fetchManifest(timeout: timeout);
    if (manifest == null) return null;

    final int latestBuild = _readInt(manifest['latestBuildNumber']) ?? 0;
    final String latestVersion =
        (manifest['latestVersionName'] as String?)?.trim().isNotEmpty == true
            ? (manifest['latestVersionName'] as String).trim()
            : '';

    final String? apkUrl = _readString(manifest['apkUrl']);
    final String? arm64Url = _readString(manifest['arm64Url']);
    final String? armeabiV7aUrl = _readString(manifest['armeabiUrl']);
    final String? x86_64Url = _readString(manifest['x64Url']);
    final String? androidPageUrl = _readString(manifest['androidPageUrl']);

    final String? apkUrlAlt = _readString(manifest['apkUrlAlt']);
    final String? arm64UrlAlt = _readString(manifest['arm64UrlAlt']);
    final String? armeabiV7aUrlAlt = _readString(manifest['armeabiUrlAlt']);
    final String? x86_64UrlAlt = _readString(manifest['x64UrlAlt']);
    final String? androidPageUrlAlt = _readString(manifest['androidPageUrlAlt']);

    final _AbiUpdateChoice abiChoice = _chooseAndroidUpdate(
      currentBuildNumber: currentBuild,
      latestBuildBase: latestBuild,
      apkUrl: apkUrl,
      arm64Url: arm64Url,
      armeabiV7aUrl: armeabiV7aUrl,
      x86_64Url: x86_64Url,
      androidPageUrl: androidPageUrl,
      apkUrlAlt: apkUrlAlt,
      arm64UrlAlt: arm64UrlAlt,
      armeabiV7aUrlAlt: armeabiV7aUrlAlt,
      x86_64UrlAlt: x86_64UrlAlt,
      androidPageUrlAlt: androidPageUrlAlt,
    );

    return AppUpdateInfo(
      currentBuildNumber: currentBuild,
      currentVersion: currentVersion,
      latestBuildNumber: latestBuild,
      latestVersion: latestVersion,
      apkUrl: apkUrl,
      arm64Url: arm64Url,
      armeabiV7aUrl: armeabiV7aUrl,
      x86_64Url: x86_64Url,
      androidPageUrl: androidPageUrl,
      apkUrlAlt: apkUrlAlt,
      arm64UrlAlt: arm64UrlAlt,
      armeabiV7aUrlAlt: armeabiV7aUrlAlt,
      x86_64UrlAlt: x86_64UrlAlt,
      androidPageUrlAlt: androidPageUrlAlt,
      latestBuildNumberEffective: abiChoice.latestBuildEffective,
      preferredUrlOverride: abiChoice.preferredUrl,
    );
  }

  _AbiUpdateChoice _chooseAndroidUpdate({
    required int currentBuildNumber,
    required int latestBuildBase,
    required String? apkUrl,
    required String? arm64Url,
    required String? armeabiV7aUrl,
    required String? x86_64Url,
    required String? androidPageUrl,
    required String? apkUrlAlt,
    required String? arm64UrlAlt,
    required String? armeabiV7aUrlAlt,
    required String? x86_64UrlAlt,
    required String? androidPageUrlAlt,
  }) {
    // When Flutter builds split-per-ABI APKs, Android may treat each ABI as a
    // slightly different versionCode. Prefer the ABI-matching APK when
    // available so upgrades work reliably.
    final Abi abi = Abi.current();

    String? preferred;

    switch (abi) {
      case Abi.androidArm64:
        preferred = arm64Url ?? arm64UrlAlt;
        break;
      case Abi.androidArm:
        preferred = armeabiV7aUrl ?? armeabiV7aUrlAlt;
        break;
      case Abi.androidX64:
        preferred = x86_64Url ?? x86_64UrlAlt;
        break;
      default:
        preferred = null;
        break;
    }

    // If we don't have an ABI-specific APK, fall back to universal/page.
    preferred ??= apkUrl ?? apkUrlAlt ?? androidPageUrl ?? androidPageUrlAlt;

    // Flutter split-per-ABI builds may use ABI-adjusted versionCodes
    // (e.g., an arm64 build can report buildNumber 6086 when the base build is
    // 4086). To avoid a false "no update" result, infer the offset from the
    // installed buildNumber and apply it to the manifest build number.
    final int offset = _inferAbiVersionCodeOffset(
      abi: abi,
      currentBuildNumber: currentBuildNumber,
      latestBuildBase: latestBuildBase,
    );
    final int latestEffective = latestBuildBase + offset;

    return _AbiUpdateChoice(
      preferredUrl: preferred,
      latestBuildEffective: latestEffective,
    );
  }

  int _inferAbiVersionCodeOffset({
    required Abi abi,
    required int currentBuildNumber,
    required int latestBuildBase,
  }) {
    if (currentBuildNumber <= 0 || latestBuildBase <= 0) {
      return 0;
    }

    // Candidate offsets observed in Flutter split-per-ABI workflows.
    // We pick the one that makes the inferred base current build closest to
    // the manifest base build.
    final List<int> candidates = switch (abi) {
      Abi.androidArm64 => const <int>[0, 2000, 1000, 3000],
      Abi.androidArm => const <int>[0, 1000, 2000, 3000],
      Abi.androidX64 => const <int>[0, 3000, 1000, 2000],
      _ => const <int>[0],
    };

    int bestOffset = 0;
    int bestScore = 1 << 30;

    for (final int offset in candidates) {
      final int baseCurrent = currentBuildNumber - offset;
      if (baseCurrent <= 0) continue;

      final int score = (baseCurrent - latestBuildBase).abs();
      if (score < bestScore) {
        bestScore = score;
        bestOffset = offset;
      }
    }

    // Sanity: if the best offset still yields a wildly different base build,
    // fall back to no offset.
    if (bestScore > 500) {
      return 0;
    }
    return bestOffset;
  }

  Future<Map<String, dynamic>?> _fetchManifest({required Duration timeout}) async {
    final HttpClient client = HttpClient();
    client.connectionTimeout = timeout;

    try {
      Map<String, dynamic>? bestManifest;
      int bestLatestBuild = -1;

      for (final String url in _manifestUrls) {
        final Uri uri = Uri.parse(url).replace(
          queryParameters: <String, String>{
            // Avoid stale cached manifests (some networks/proxies ignore headers).
            't': DateTime.now().millisecondsSinceEpoch.toString(),
          },
        );

        try {
          final HttpClientRequest request = await client.getUrl(uri).timeout(timeout);
          request.headers.set(HttpHeaders.acceptHeader, 'application/json');

          final HttpClientResponse response = await request.close().timeout(timeout);
          if (response.statusCode != 200) {
            continue;
          }

          final String body =
              await response.transform(utf8.decoder).join().timeout(timeout);
          final Object? decoded = jsonDecode(body);
          Map<String, dynamic>? manifest;
          if (decoded is Map<String, dynamic>) {
            manifest = decoded;
          } else if (decoded is Map) {
            manifest = decoded.map((Object? key, Object? value) {
              return MapEntry<String, dynamic>(key.toString(), value);
            });
          }

          if (manifest != null) {
            final int latestBuild = _readInt(manifest['latestBuildNumber']) ?? 0;
            if (latestBuild > bestLatestBuild) {
              bestLatestBuild = latestBuild;
              bestManifest = manifest;
            }
          }
        } catch (_) {
          // Try next URL.
          continue;
        }
      }

      return bestManifest;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  int? _readInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  String? _readString(Object? value) {
    if (value is String) {
      final String trimmed = value.trim();
      return trimmed.isEmpty ? null : trimmed;
    }
    return null;
  }
}

class _AbiUpdateChoice {
  const _AbiUpdateChoice({required this.preferredUrl, required this.latestBuildEffective});

  final String? preferredUrl;
  final int latestBuildEffective;
}
