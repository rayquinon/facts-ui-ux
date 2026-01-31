import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:facts/reports/attendance_mark.dart';
import 'package:facts/reports/docx_attendance_builder.dart';
import 'package:facts/reports/docx_attendance_template_builder.dart';
import 'package:docx_template_fork/docx_template_fork.dart';

void main() {
  test('DOCX template fills content controls', () async {
    final Uint8List templateBytes = Uint8List.fromList(
      await File('assets/reports/template.docx.docx').readAsBytes(),
    );

    // Sanity-check: make sure the template actually exposes the expected keys.
    final DocxTemplate tagsDocx = await DocxTemplate.fromBytes(
      Uint8List.fromList(templateBytes),
    );
    final List<String> tags = tagsDocx.getTags();
    expect(tags, contains('officeUnit'));
    expect(tags, contains('subject'));
    expect(tags, contains('students'));

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

    if (Platform.environment.containsKey('DOCX_DEBUG')) {
      await Directory('build').create(recursive: true);
      await File('build/test_out.docx').writeAsBytes(out);
    }

    final Archive zip = ZipDecoder().decodeBytes(out);

    bool foundOffice = false;
    bool foundSubject = false;
    bool foundStudent = false;

    for (final ArchiveFile file in zip.files.cast<ArchiveFile>()) {
      if (!file.name.startsWith('word/') || !file.name.endsWith('.xml')) {
        continue;
      }

      final List<int> bytes = file.content as List<int>;
      final String xml = utf8.decode(bytes, allowMalformed: true);

      foundOffice = foundOffice || xml.contains('TEST_OFFICE');
      foundSubject = foundSubject || xml.contains('TEST_SUBJECT');
      foundStudent = foundStudent || xml.contains('TEST_STUDENT');
    }

    expect(foundOffice, isTrue);
    expect(foundSubject, isTrue);
    expect(foundStudent, isTrue);
  });
}
