import 'dart:io' show Platform, Process;

import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

Future<bool> openExternalUrl(String url) async {
  try {
    return await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
  } on MissingPluginException {
    // Desktop fallback when the plugin isn't registered.
    if (Platform.isWindows) {
      await Process.run('cmd', <String>['/c', 'start', '', url]);
      return true;
    }
    if (Platform.isMacOS) {
      await Process.run('open', <String>[url]);
      return true;
    }
    if (Platform.isLinux) {
      await Process.run('xdg-open', <String>[url]);
      return true;
    }
    rethrow;
  }
}
