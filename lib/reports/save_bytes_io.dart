import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:simple_file_saver/simple_file_saver.dart';

Future<String?> saveBytesAsFileImpl(Uint8List bytes, String fileName) async {
  final String safeFileName = fileName.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');

  // Android: save into public Downloads so users can find it easily.
  if (Platform.isAndroid) {
    final int dot = safeFileName.lastIndexOf('.');
    final String basename = (dot > 0) ? safeFileName.substring(0, dot) : safeFileName;
    final String extension = (dot > 0 && dot < safeFileName.length - 1)
        ? safeFileName.substring(dot + 1)
        : '';

    return SimpleFileSaver.saveFile(
      fileInfo: FileSaveInfo.fromBytes(
        bytes: bytes,
        basename: basename.isEmpty ? 'export' : basename,
        extension: extension.isEmpty ? 'bin' : extension,
      ),
    );
  }

  // Other IO platforms: keep current behavior.
  final Directory dir = await getApplicationDocumentsDirectory();
  final File file = File('${dir.path}${Platform.pathSeparator}$safeFileName');
  await file.writeAsBytes(bytes, flush: true);
  return file.path;
}
