import 'dart:async';
import 'dart:convert';
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
    final String? androidPageUrl = _readString(manifest['androidPageUrl']);

    final String? apkUrlAlt = _readString(manifest['apkUrlAlt']);
    final String? arm64UrlAlt = _readString(manifest['arm64UrlAlt']);
    final String? androidPageUrlAlt = _readString(manifest['androidPageUrlAlt']);

    return AppUpdateInfo(
      currentBuildNumber: currentBuild,
      currentVersion: currentVersion,
      latestBuildNumber: latestBuild,
      latestVersion: latestVersion,
      apkUrl: apkUrl,
      arm64Url: arm64Url,
      androidPageUrl: androidPageUrl,
      apkUrlAlt: apkUrlAlt,
      arm64UrlAlt: arm64UrlAlt,
      androidPageUrlAlt: androidPageUrlAlt,
    );
  }

  Future<Map<String, dynamic>?> _fetchManifest({required Duration timeout}) async {
    final HttpClient client = HttpClient();
    client.connectionTimeout = timeout;

    try {
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
          if (decoded is Map<String, dynamic>) {
            return decoded;
          }
          if (decoded is Map) {
            return decoded.map((Object? key, Object? value) {
              return MapEntry<String, dynamic>(key.toString(), value);
            });
          }
        } catch (_) {
          // Try next URL.
          continue;
        }
      }
      return null;
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
