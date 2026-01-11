import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

class CrashReporter {
  CrashReporter._();

  static File? _file;

  static Future<void> init() async {
    try {
      final Directory dir = await getApplicationDocumentsDirectory();
      _file = File('${dir.path}${Platform.pathSeparator}last_flutter_error.txt');
    } catch (_) {
      // Ignore: crash reporting is best-effort.
      _file = null;
    }
  }

  static Future<void> record({required String error, StackTrace? stackTrace}) async {
    final File? file = _file;
    if (file == null) return;

    final String payload = [
      DateTime.now().toIso8601String(),
      error,
      if (stackTrace != null) stackTrace.toString(),
    ].join('\n\n');

    try {
      await file.writeAsString(payload, flush: true);
    } catch (_) {
      // Ignore.
    }
  }

  static Future<String?> readLast() async {
    final File? file = _file;
    if (file == null) return null;
    try {
      if (!await file.exists()) return null;
      final String contents = await file.readAsString();
      if (contents.trim().isEmpty) return null;
      return contents;
    } catch (_) {
      return null;
    }
  }

  static Future<void> clear() async {
    final File? file = _file;
    if (file == null) return;
    try {
      if (await file.exists()) {
        await file.writeAsString('', flush: true);
      }
    } catch (_) {
      // Ignore.
    }
  }

  /// Hooks into the Flutter and platform dispatchers.
  /// Call after [init].
  static void installGlobalHandlers() {
    FlutterError.onError = (FlutterErrorDetails details) {
      FlutterError.presentError(details);
      // Best effort: persist the error so we can show it after restart.
      // (This is the key when the app goes to the red error screen.)
      record(
        error: details.toString(),
      );
    };

    PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
      // Persist, but still allow default behavior.
      record(error: error.toString(), stackTrace: stack);
      return false;
    };

    ErrorWidget.builder = (FlutterErrorDetails details) {
      // Persist again here (some failures hit ErrorWidget directly).
      record(
        error: details.toString(),
      );

      // Keep the default error UI.
      return ErrorWidget(details.exception);
    };
  }
}
