// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'package:facts/reports/attendance_mark.dart';
import 'package:facts/reports/docx_attendance_builder.dart';
import 'package:facts/reports/docx_attendance_template_builder.dart';
import 'package:docx_template_fork/docx_template_fork.dart';

Future<void> main(List<String> args) async {
  // Safety guard: this script is for local debugging only.
  // Run with `dart run tool/debug_docx_fill.dart --force` OR set DOCX_DEBUG=1.
  if (!Platform.environment.containsKey('DOCX_DEBUG') && !args.contains('--force')) {
    print('Refusing to run debug tool without explicit opt-in.');
    print('Run: dart run tool/debug_docx_fill.dart --force');
    print('Or set env var: DOCX_DEBUG=1');
    exitCode = 2;
    return;
  }

  final Uint8List templateBytes = Uint8List.fromList(
    await File('assets/reports/template.docx.docx').readAsBytes(),
  );

  final DocxTemplate t = await DocxTemplate.fromBytes(Uint8List.fromList(templateBytes));
  final tags = t.getTags();
  for (final k in ['students', 'no', 'studentName', 'courseYear', 'd01', 'm01']) {
    print('tag $k: ${tags.contains(k)}');
  }

  final DocxAttendanceHeader header = DocxAttendanceHeader(
    officeOrUnit: 'TEST_OFFICE',
    subject: 'TEST_SUBJECT',
    classSchedule: 'TEST_SCHEDULE',
    courseCode: 'TEST_CODE',
    room: 'TEST_ROOM',
    documentCodeNo: 'TEST_DOC',
    revisionNo: 'TEST_REV',
    effectiveDate: 'TEST_DATE',
  );

  final DateTime day = DateTime(2026, 1, 1);

  final Uint8List out = await buildAttendanceDocxFromContentControls(
    templateDocxBytes: templateBytes,
    header: header,
    sessionDays: <DateTime>[day],
    students: <DocxAttendanceRow>[
      DocxAttendanceRow(
        studentName: 'TEST_STUDENT',
        courseYear: 'TEST_CY',
        marksByDay: <DateTime, AttendanceMark>{
          DateTime(day.year, day.month, day.day): AttendanceMark.present,
        },
      ),
    ],
    checkedBy: 'TEST_CHECKED_BY',
    submittedTo: 'TEST_SUBMITTED_TO',
  );

  final outPath = 'build/debug_out.docx';
  await Directory('build').create(recursive: true);
  await File(outPath).writeAsBytes(out);
  print('Wrote $outPath (${out.length} bytes)');

  final Archive zip = ZipDecoder().decodeBytes(out);
  bool found = false;
  for (final ArchiveFile f in zip.files.cast<ArchiveFile>()) {
    if (!f.name.startsWith('word/') || !f.name.endsWith('.xml')) continue;
    final List<int> bytes = f.content as List<int>;
    final xml = utf8.decode(bytes, allowMalformed: true);
    if (xml.contains('TEST_OFFICE') || xml.contains('TEST_SUBJECT') || xml.contains('TEST_STUDENT')) {
      print('Found sentinel in ${f.name}');
      found = true;
      break;
    }
  }
  print('Found sentinel anywhere: $found');
}
