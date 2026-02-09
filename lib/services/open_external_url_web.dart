import 'package:web/web.dart' as web;

Future<bool> openExternalUrl(String url) async {
  // Returns null when blocked by popup blockers.
  final web.Window? opened = web.window.open(url, '_blank');
  return opened != null;
}
