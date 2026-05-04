import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'app_update_types.dart';

class AppUpdateService {
  static final AppUpdateService instance = AppUpdateService._();

  AppUpdateService._();

  static const MethodChannel _channel = MethodChannel('facts.app_update');

  // In-memory guard to avoid concurrent manifest checks/prompts.
  static Future<AppUpdateInfo?>? _ongoingCheck;

  // Persistent marker file written while an update download/install flow
  // has been initiated. This prevents re-prompting if the app is relaunched
  // during an in-progress install (the app process may be killed by the
  // package installer). The file contains an expiry timestamp.
  static const String _kUpdateInProgressFile = 'update_in_progress.json';

  // Keep this as a plain Hosting file to avoid Firestore/Remote Config costs.
  static const List<String> _manifestUrls = <String>[
    // Custom domain (preferred).
    'https://facts.shiro.codes/downloads/version.json',
    // Default Firebase Hosting domain (fallback).
    'https://simple-distributed-database.web.app/downloads/version.json',
  ];

  Future<AppUpdateInfo?> checkForUpdate({
    Duration timeout = const Duration(seconds: 3),
    bool force = false,
  }) async {
    // If a check is already running, wait for and return its result to avoid
    // duplicate prompts and races.
    if (_ongoingCheck != null) {
      try {
        return await _ongoingCheck!;
      } catch (_) {
        // If the prior check failed, continue with a fresh one.
      }
    }

    Future<AppUpdateInfo?> _run() async {
      final PackageInfo info = await PackageInfo.fromPlatform();
      final int currentBuild = int.tryParse(info.buildNumber) ?? 0;
      final String currentVersion = info.version;

      // If an update flow was recently initiated, skip checks for a short
      // window to avoid repeatedly prompting while the installer is active.
      try {
        if (Platform.isAndroid) {
          final Directory supportDir = await getApplicationSupportDirectory();
          final File inprog = File('${supportDir.path}${Platform.pathSeparator}$_kUpdateInProgressFile');
          if (await inprog.exists()) {
            try {
              final String content = await inprog.readAsString();
              final Object? decoded = jsonDecode(content);
              if (decoded is Map<String, dynamic>) {
                final int? pendingBuild = _readInt(decoded['buildNumber']);
                final String? expires = decoded['expiresAtUtc'] as String?;
                if (expires != null) {
                  try {
                    final DateTime until = DateTime.parse(expires).toUtc();
                    if (pendingBuild != null && currentBuild >= pendingBuild) {
                      try {
                        await inprog.delete();
                      } catch (_) {
                        // Best-effort.
                      }
                    } else if (DateTime.now().toUtc().isBefore(until)) {
                      return null;
                    } else {
                      // expired marker; remove it
                      try {
                        await inprog.delete();
                      } catch (_) {
                        // Best-effort.
                      }
                    }
                  } catch (_) {
                    // ignore parse errors and continue
                  }
                }
              }
            } catch (_) {
              // ignore and continue
            }
          }
        }
      } catch (_) {
        // Best-effort only.
      }

      final Map<String, dynamic>? manifest = await _fetchManifest(
        timeout: timeout,
      );
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
    final String? androidPageUrlAlt = _readString(
      manifest['androidPageUrlAlt'],
    );

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
    // Avoid repeatedly prompting the user for the same manifest when they
    // have already seen it and not updated. Persist a small state file that
    // records the last manifest build shown to the user along with the
    // current app build at that time. If we detect the manifest build is the
    // same and the device build hasn't changed, skip reporting an update.
    if (!force) {
      try {
        final Directory supportDir = await getApplicationSupportDirectory();
        final File stateFile = File('${supportDir.path}${Platform.pathSeparator}update_prompt_state.json');
        if (await stateFile.exists()) {
          try {
            final String content = await stateFile.readAsString();
            final Object? decoded = jsonDecode(content);
            if (decoded is Map<String, dynamic>) {
              final int? seenLatest = _readInt(decoded['latestBuild']);
              final int? seenCurrent = _readInt(decoded['currentBuildWhenShown']);
              final String? snoozed = decoded['snoozedUntilUtc'] as String?;
              if (snoozed != null) {
                try {
                  final DateTime snoozedUntil = DateTime.parse(snoozed);
                  if (DateTime.now().toUtc().isBefore(snoozedUntil)) {
                    // We're within a user-initiated snooze window; skip update checks.
                    return null;
                  }
                } catch (_) {
                  // Ignore parse errors.
                }
              }
              if (seenLatest != null && seenCurrent != null) {
                if (seenLatest == latestBuild && seenCurrent == currentBuild) {
                  // User has already been shown this exact manifest while
                  // running the same app build; don't keep nagging.
                  return null;
                }
              }
            }
          } catch (_) {
            // Ignore parse errors and allow update checks to proceed.
          }
        }
      } catch (_) {
        // Best-effort only. If storage isn't available, continue normally.
      }
    }

    final AppUpdateInfo infoObj = AppUpdateInfo(
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
      preferredUrlOverride: abiChoice.preferredUrl,
      latestBuildNumberEffective: abiChoice.latestBuildEffective,
    );

      // Persist that we are about to (or will) show this manifest for this
      // device build. This prevents repeated prompts for the same manifest
      // when the user dismisses the dialog or the install does not complete.
      unawaited(() async {
        try {
          final Directory supportDir = await getApplicationSupportDirectory();
          if (!await supportDir.exists()) {
            await supportDir.create(recursive: true);
          }
          final File stateFile = File('${supportDir.path}${Platform.pathSeparator}update_prompt_state.json');
          final Map<String, Object> payload = <String, Object>{
            'latestBuild': latestBuild,
            'currentBuildWhenShown': currentBuild,
            'shownAtUtc': DateTime.now().toUtc().toIso8601String(),
          };
          await stateFile.writeAsString(jsonEncode(payload));
        } catch (_) {
          // Best-effort.
        }
      }());

      return infoObj;
    }

    _ongoingCheck = _run();
    try {
      return await _ongoingCheck!;
    } finally {
      _ongoingCheck = null;
    }
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

  Future<Map<String, dynamic>?> _fetchManifest({
    required Duration timeout,
  }) async {
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
          final HttpClientRequest request = await client
              .getUrl(uri)
              .timeout(timeout);
          request.headers.set(HttpHeaders.acceptHeader, 'application/json');

          final HttpClientResponse response = await request.close().timeout(
            timeout,
          );
          if (response.statusCode != 200) {
            continue;
          }

          final String body = await response
              .transform(utf8.decoder)
              .join()
              .timeout(timeout);
          // Some hosting pipelines may accidentally write UTF-8 BOM (\uFEFF)
          // into JSON files. Dart's jsonDecode does not ignore BOM.
          final String cleanedBody = body.replaceFirst(RegExp(r'^\uFEFF+'), '');
          final Object? decoded = jsonDecode(cleanedBody);
          Map<String, dynamic>? manifest;
          if (decoded is Map<String, dynamic>) {
            manifest = decoded;
          } else if (decoded is Map) {
            manifest = decoded.map((Object? key, Object? value) {
              return MapEntry<String, dynamic>(key.toString(), value);
            });
          }

          if (manifest != null) {
            final int latestBuild =
                _readInt(manifest['latestBuildNumber']) ?? 0;
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

  Future<bool> canRequestPackageInstalls() async {
    if (!Platform.isAndroid) return false;
    final bool? result = await _channel.invokeMethod<bool>(
      'canRequestPackageInstalls',
    );
    return result ?? false;
  }

  Future<void> openUnknownSourcesSettings() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('openUnknownSourcesSettings');
  }

  /// Downloads the APK and launches the Android installer.
  ///
  /// Note: Android will still require the user to confirm install.
  /// If "Install unknown apps" is disabled for this app, this method will
  /// throw [AppUpdateNeedsInstallPermission] after opening Settings.
  Future<void> downloadAndInstallUpdate(
    AppUpdateInfo update, {
    Duration timeout = const Duration(minutes: 3),
    void Function(int receivedBytes, int totalBytes)? onProgress,
  }) async {
    if (!Platform.isAndroid) {
      throw const AppUpdateException('In-app APK install is Android-only.');
    }

    final bool allowed = await canRequestPackageInstalls();
    if (!allowed) {
      await openUnknownSourcesSettings();
      throw const AppUpdateNeedsInstallPermission();
    }

    final String? url = _chooseApkUrl(update);
    if (url == null) {
      throw const AppUpdateException('No APK URL available for update.');
    }

    final int buildNumber = update.effectiveLatestBuildNumber;

    // Write a persistent in-progress marker so if the app is restarted while
    // the installer is active we don't immediately re-prompt the user.
    File? markerFile;
    try {
      final Directory supportDir = await getApplicationSupportDirectory();
      if (!await supportDir.exists()) await supportDir.create(recursive: true);
      markerFile = File('${supportDir.path}${Platform.pathSeparator}$_kUpdateInProgressFile');
      final DateTime started = DateTime.now().toUtc();
      final DateTime expires = started.add(const Duration(minutes: 30));
      final Map<String, Object?> marker = <String, Object?>{
        'buildNumber': buildNumber,
        'startedAtUtc': started.toIso8601String(),
        'expiresAtUtc': expires.toIso8601String(),
        'url': url,
      };
      await markerFile.writeAsString(jsonEncode(marker));
    } catch (_) {
      markerFile = null; // Best-effort
    }

    try {
      final File apkFile =
          await _getExistingApkFile(buildNumber) ??
          await _downloadApk(
            url: url,
            buildNumber: buildNumber,
            timeout: timeout,
            onProgress: onProgress,
          );

      await _channel.invokeMethod<void>('installApk', <String, Object?>{
        'path': apkFile.path,
      });
    } catch (e) {
      // Remove persistent marker on failure so future checks can proceed.
      try {
        if (markerFile != null && await markerFile.exists()) {
          await markerFile.delete();
        }
      } catch (_) {
        // Best-effort.
      }
      rethrow;
    }
  }

  Future<File?> _getExistingApkFile(int buildNumber) async {
    try {
      final Directory dir = await getTemporaryDirectory();
      final String fileName = 'facts-update-$buildNumber.apk';
      final File file = File('${dir.path}${Platform.pathSeparator}$fileName');
      if (!await file.exists()) return null;
      final int length = await file.length();
      // Basic sanity: reject tiny/partial files.
      if (length < 1024 * 1024) {
        try {
          await file.delete();
        } catch (_) {
          // Best-effort.
        }
        return null;
      }
      return file;
    } catch (_) {
      return null;
    }
  }

  String? _chooseApkUrl(AppUpdateInfo update) {
    final List<String?> candidates = <String?>[
      update.preferredUrlOverride,
      update.apkUrl,
      update.arm64Url,
      update.armeabiV7aUrl,
      update.x86_64Url,
      update.apkUrlAlt,
      update.arm64UrlAlt,
      update.armeabiV7aUrlAlt,
      update.x86_64UrlAlt,
    ];

    for (final String? url in candidates) {
      if (url == null) continue;
      final String trimmed = url.trim();
      if (trimmed.isEmpty) continue;
      final Uri? uri = Uri.tryParse(trimmed);
      if (uri == null) continue;
      final String lowerPath = uri.path.toLowerCase();
      if (lowerPath.endsWith('.apk')) return trimmed;
    }

    return null;
  }

  Future<File> _downloadApk({
    required String url,
    required int buildNumber,
    required Duration timeout,
    void Function(int receivedBytes, int totalBytes)? onProgress,
  }) async {
    AppUpdateException? lastError;
    for (int attempt = 1; attempt <= 2; attempt++) {
      try {
        return await _downloadApkOnce(
          url: url,
          buildNumber: buildNumber,
          timeout: timeout,
          onProgress: onProgress,
        );
      } on AppUpdateException catch (e) {
        lastError = e;
        if (attempt >= 2) {
          rethrow;
        }
      }
    }

    throw lastError ?? const AppUpdateException('APK download failed.');
  }

  Future<File> _downloadApkOnce({
    required String url,
    required int buildNumber,
    required Duration timeout,
    void Function(int receivedBytes, int totalBytes)? onProgress,
  }) async {
    final Directory dir = await getTemporaryDirectory();
    final String fileName = 'facts-update-$buildNumber.apk';
    final File outFile = File('${dir.path}${Platform.pathSeparator}$fileName');

    // Best-effort: remove any prior partial download.
    try {
      if (await outFile.exists()) {
        await outFile.delete();
      }
    } catch (_) {
      // Best-effort.
    }

    final HttpClient client = HttpClient();
    client.connectionTimeout = timeout;
    // Keep transfer bytes as-is so size checks are reliable for APK binaries.
    client.autoUncompress = false;

    try {
      final Uri parsed = Uri.parse(url);
      final Uri uri = parsed.replace(
        queryParameters: <String, String>{
          ...parsed.queryParameters,
          // Avoid stale cached APK downloads.
          't': DateTime.now().millisecondsSinceEpoch.toString(),
        },
      );

      final HttpClientRequest request = await client
          .getUrl(uri)
          .timeout(timeout);
      request.headers.set(HttpHeaders.acceptHeader, '*/*');
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');

      final HttpClientResponse response = await request.close().timeout(
        timeout,
      );
      if (response.statusCode != 200) {
        throw AppUpdateException(
          'APK download failed (HTTP ${response.statusCode}).',
        );
      }

      final int total = response.contentLength;
      int received = 0;

      final IOSink sink = outFile.openWrite();
      try {
        await for (final List<int> chunk in response) {
          sink.add(chunk);
          received += chunk.length;
          if (onProgress != null) {
            onProgress(received, total);
          }
        }
      } finally {
        await sink.flush();
        await sink.close();
      }

      final int actual = await outFile.length();
      if (total > 0 && actual < total) {
        throw AppUpdateException(
          'APK download incomplete ($actual/$total bytes).',
        );
      }

      if (!await outFile.exists() || actual <= 0) {
        throw const AppUpdateException('Download failed to write APK file.');
      }

      return outFile;
    } catch (e) {
      try {
        if (await outFile.exists()) {
          await outFile.delete();
        }
      } catch (_) {
        // Best-effort.
      }
      rethrow;
    } finally {
      client.close(force: true);
    }
  }
}

class AppUpdateException implements Exception {
  const AppUpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}

class AppUpdateNeedsInstallPermission extends AppUpdateException {
  const AppUpdateNeedsInstallPermission()
    : super('Install permission required.');
}

class _AbiUpdateChoice {
  const _AbiUpdateChoice({
    required this.preferredUrl,
    required this.latestBuildEffective,
  });

  final String? preferredUrl;
  final int latestBuildEffective;
}
