import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

Future<String?> saveBytesAsFileImpl(Uint8List bytes, String fileName) async {
  final Directory dir = await getApplicationDocumentsDirectory();
  final String safeName = fileName.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
  final File file = File('${dir.path}${Platform.pathSeparator}$safeName');
  await file.writeAsBytes(bytes, flush: true);
  return file.path;
}
