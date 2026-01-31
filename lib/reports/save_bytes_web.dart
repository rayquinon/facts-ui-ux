// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:typed_data';
import 'dart:html' as html;

Future<String?> saveBytesAsFileImpl(Uint8List bytes, String fileName) async {
  final html.Blob blob = html.Blob(
    <dynamic>[bytes],
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  );
  final String url = html.Url.createObjectUrlFromBlob(blob);
  final html.AnchorElement a = html.AnchorElement(href: url)
    ..download = fileName
    ..style.display = 'none';
  final html.Element? body = html.document.body;
  if (body == null) {
    html.Url.revokeObjectUrl(url);
    return null;
  }

  body.append(a);
  try {
    a.click();
  } finally {
    a.remove();
    html.Url.revokeObjectUrl(url);
  }
  return null;
}
