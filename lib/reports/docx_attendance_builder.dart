import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import 'attendance_mark.dart';

const String _wNs =
    'http://schemas.openxmlformats.org/wordprocessingml/2006/main';

const int _templateDatesRowIndex = 4;
const int _templateFirstStudentRowIndex = 5;
const int _templateStudentRowsPerPage = 40;
const int _templateFooterRowStartIndex = 46;

const int _templateNameCellIndex = 1;
const int _templateCourseCellIndex = 2;
const int _templateFirstDateCellIndex = 3;
const int _templateLastDateCellIndex = 15;

int get templateDatesPerPage =>
    (_templateLastDateCellIndex - _templateFirstDateCellIndex + 1);

String attendanceMarkSymbol(AttendanceMark mark) {
  switch (mark) {
    case AttendanceMark.present:
      return '✓';
    case AttendanceMark.absent:
      return 'A';
    case AttendanceMark.late:
      return 'L';
    case AttendanceMark.excused:
      return 'E';
  }
}

class DocxAttendanceRow {
  const DocxAttendanceRow({
    required this.studentName,
    required this.courseYear,
    required this.marksByDay,
  });

  final String studentName;
  final String courseYear;
  final Map<DateTime, AttendanceMark> marksByDay;
}

class DocxAttendanceHeader {
  const DocxAttendanceHeader({
    required this.officeOrUnit,
    required this.subject,
    required this.classSchedule,
    required this.courseCode,
    required this.room,
    this.documentCodeNo,
    this.revisionNo,
    this.effectiveDate,
  });

  final String officeOrUnit;
  final String subject;
  final String classSchedule;
  final String courseCode;
  final String room;

  // Optional template metadata (top-right header block).
  final String? documentCodeNo;
  final String? revisionNo;
  final String? effectiveDate;
}

/// Fills the university attendance monitoring sheet template and returns a
/// `.docx` file as bytes.
///
/// The template is expected to contain a single main table, with:
/// - rows 0..2 header fields
/// - row 3 column headings
/// - row 4 date headings
/// - rows 5..44 student rows (40)
/// - rows 46..47 footer (checked by / submitted to)
Future<Uint8List> buildAttendanceDocxFromTemplate({
  required Uint8List templateDocxBytes,
  required DocxAttendanceHeader header,
  required List<DateTime> sessionDays,
  required List<DocxAttendanceRow> students,
  String? checkedBy,
  String? submittedTo,
}) async {
  final int datesPerPage = templateDatesPerPage;
  final int studentRowsPerPage = _templateStudentRowsPerPage;

  final List<List<DateTime>> datePages = <List<DateTime>>[];
  for (int i = 0; i < sessionDays.length; i += datesPerPage) {
    datePages.add(
      sessionDays.sublist(i, (i + datesPerPage).clamp(0, sessionDays.length)),
    );
  }
  if (datePages.isEmpty) {
    datePages.add(<DateTime>[]);
  }

  final List<List<DocxAttendanceRow>> studentPages =
      <List<DocxAttendanceRow>>[];
  for (int i = 0; i < students.length; i += studentRowsPerPage) {
    studentPages.add(
      students.sublist(i, (i + studentRowsPerPage).clamp(0, students.length)),
    );
  }
  if (studentPages.isEmpty) {
    studentPages.add(<DocxAttendanceRow>[]);
  }

  final Archive inputArchive = ZipDecoder().decodeBytes(templateDocxBytes);
  final ArchiveFile? docXmlFile = inputArchive.files
      .whereType<ArchiveFile>()
      .cast<ArchiveFile?>()
      .firstWhere(
        (ArchiveFile? f) => f?.name == 'word/document.xml',
        orElse: () => null,
      );
  if (docXmlFile == null) {
    throw StateError('Template DOCX is missing word/document.xml');
  }

  final String xmlString = utf8.decode(docXmlFile.content as List<int>);
  final XmlDocument document = XmlDocument.parse(xmlString);

  final String namespaceDecls = document.rootElement.attributes
      .where(
        (XmlAttribute a) => a.name.prefix == 'xmlns' || a.name.local == 'xmlns',
      )
      .map((XmlAttribute a) => '${a.name.qualified}="${a.value}"')
      .join(' ');

  // Some `xml` versions may omit xmlns attributes from `attributes`. Ensure we
  // always have the `w` namespace available for re-parsing/cloning.
  final String wrapperNamespaceDecls =
      namespaceDecls.contains('xmlns:w="$_wNs"')
      ? namespaceDecls
      : '${namespaceDecls.isEmpty ? '' : '$namespaceDecls '}xmlns:w="$_wNs"';

  final XmlElement body = document
      .findAllElements('body', namespace: _wNs)
      .cast<XmlElement>()
      .first;

  final XmlElement? sectPr = body.children
      .whereType<XmlElement>()
      .cast<XmlElement?>()
      .firstWhere(
        (XmlElement? e) =>
            e?.name.local == 'sectPr' && e?.name.namespaceUri == _wNs,
        orElse: () => null,
      );

  // Prefer the table with the most rows to avoid selecting incidental tables.
  final Set<XmlElement> candidateTableSet = <XmlElement>{
    ...body.findAllElements('tbl', namespace: _wNs),
    ...body.findAllElements('tbl'),
  };
  final List<XmlElement> candidateTables = candidateTableSet.toList();
  if (candidateTables.isEmpty) {
    throw StateError('Template DOCX is missing a table (w:tbl).');
  }
  XmlElement baseTable = candidateTables.first;
  int bestRowCount = -1;
  for (final XmlElement table in candidateTables) {
    final int rowCount = table.findAllElements('tr', namespace: _wNs).length;
    final int fallbackRowCount = table.findAllElements('tr').length;
    final int score = rowCount > 0 ? rowCount : fallbackRowCount;
    if (score > bestRowCount) {
      bestRowCount = score;
      baseTable = table;
    }
  }

  // Important: the template typically declares namespaces like `xmlns:w` on the
  // root document element, not on the table itself. If we serialize the table
  // alone and parse it back, the prefixes become unbound and the `xml` package
  // will treat those elements as having no namespace.
  final String baseTableWrapperXml =
      '<root${wrapperNamespaceDecls.isEmpty ? '' : ' $wrapperNamespaceDecls'}>'
      '${baseTable.toXmlString()}'
      '</root>';

  body.children
    ..clear()
    ..addAll(<XmlNode>[]);

  for (
    int datePageIndex = 0;
    datePageIndex < datePages.length;
    datePageIndex++
  ) {
    for (
      int studentPageIndex = 0;
      studentPageIndex < studentPages.length;
      studentPageIndex++
    ) {
      final XmlElement pageTable = XmlDocument.parse(
        baseTableWrapperXml,
      ).findAllElements('tbl', namespace: _wNs).first.copy();
      _fillSingleTable(
        table: pageTable,
        header: header,
        sessionDays: datePages[datePageIndex],
        students: studentPages[studentPageIndex],
        checkedBy: checkedBy,
        submittedTo: submittedTo,
      );

      body.children.add(pageTable);

      final bool isLastPage =
          datePageIndex == datePages.length - 1 &&
          studentPageIndex == studentPages.length - 1;
      if (!isLastPage) {
        body.children.add(_pageBreakParagraph());
      }
    }
  }

  if (sectPr != null) {
    body.children.add(sectPr.copy());
  }

  final String updatedXml = document.toXmlString(pretty: false);
  final List<int> updatedXmlBytes = utf8.encode(updatedXml);

  final Archive outputArchive = Archive();
  for (final ArchiveFile file in inputArchive.files.cast<ArchiveFile>()) {
    if (file.name == 'word/document.xml') {
      outputArchive.addFile(
        ArchiveFile(file.name, updatedXmlBytes.length, updatedXmlBytes),
      );
    } else {
      outputArchive.addFile(file);
    }
  }

  final List<int> outBytes = ZipEncoder().encode(outputArchive);
  return Uint8List.fromList(outBytes);
}

XmlNode _pageBreakParagraph() {
  return XmlElement(XmlName('p', 'w'), const <XmlAttribute>[], <XmlNode>[
    XmlElement(XmlName('r', 'w'), const <XmlAttribute>[], <XmlNode>[
      XmlElement(XmlName('br', 'w'), <XmlAttribute>[
        XmlAttribute(XmlName('type', 'w'), 'page'),
      ]),
    ]),
  ]);
}

void _fillSingleTable({
  required XmlElement table,
  required DocxAttendanceHeader header,
  required List<DateTime> sessionDays,
  required List<DocxAttendanceRow> students,
  required String? checkedBy,
  required String? submittedTo,
}) {
  List<XmlElement> rows = table
      .findElements('tr', namespace: _wNs)
      .cast<XmlElement>()
      .toList();
  if (rows.isEmpty) {
    rows = table.findElements('tr').cast<XmlElement>().toList();
  }
  if (rows.isEmpty) {
    rows = table
        .findAllElements('tr', namespace: _wNs)
        .cast<XmlElement>()
        .toList();
  }
  if (rows.isEmpty) {
    rows = table.findAllElements('tr').cast<XmlElement>().toList();
  }
  if (rows.length < _templateFooterRowStartIndex + 1) {
    throw StateError('Unexpected template table row count: ${rows.length}');
  }

  _setRowCellText(
    rows,
    rowIndex: 0,
    cellIndex: 0,
    value: _labelValue('Office / Unit:', header.officeOrUnit),
  );
  _setRowCellText(
    rows,
    rowIndex: 1,
    cellIndex: 0,
    value: _labelValue('Subject:', header.subject),
  );
  _setRowCellText(
    rows,
    rowIndex: 1,
    cellIndex: 1,
    value: _labelValue('Class Schedule:', header.classSchedule),
  );
  _setRowCellText(
    rows,
    rowIndex: 2,
    cellIndex: 0,
    value: _labelValue('Course Code:', header.courseCode),
  );
  _setRowCellText(
    rows,
    rowIndex: 2,
    cellIndex: 1,
    value: _labelValue('Bldg. and Room No.:', header.room),
  );

  // Dates header row.
  for (int i = 0; i < templateDatesPerPage; i++) {
    final int cellIndex = _templateFirstDateCellIndex + i;
    final String label = i < sessionDays.length
        ? sessionDays[i].day.toString().padLeft(2, '0')
        : '';
    _setRowCellText(
      rows,
      rowIndex: _templateDatesRowIndex,
      cellIndex: cellIndex,
      value: label,
    );
  }

  // Student rows.
  for (int r = 0; r < _templateStudentRowsPerPage; r++) {
    final int rowIndex = _templateFirstStudentRowIndex + r;
    final DocxAttendanceRow? rowData = r < students.length ? students[r] : null;

    _setRowCellText(
      rows,
      rowIndex: rowIndex,
      cellIndex: _templateNameCellIndex,
      value: rowData?.studentName ?? '',
    );
    _setRowCellText(
      rows,
      rowIndex: rowIndex,
      cellIndex: _templateCourseCellIndex,
      value: rowData?.courseYear ?? '',
    );

    for (int d = 0; d < templateDatesPerPage; d++) {
      final int cellIndex = _templateFirstDateCellIndex + d;
      String markText = '';
      if (rowData != null && d < sessionDays.length) {
        final DateTime dayKey = DateTime(
          sessionDays[d].year,
          sessionDays[d].month,
          sessionDays[d].day,
        );
        final AttendanceMark? mark = rowData.marksByDay[dayKey];
        markText = mark == null ? '' : attendanceMarkSymbol(mark);
      }
      _setRowCellText(
        rows,
        rowIndex: rowIndex,
        cellIndex: cellIndex,
        value: markText,
      );
    }
  }

  // Footer: clear baked-in names unless specified.
  if (rows.length > _templateFooterRowStartIndex) {
    _setRowCellText(
      rows,
      rowIndex: _templateFooterRowStartIndex,
      cellIndex: 1,
      value: checkedBy ?? '',
    );
    _setRowCellText(
      rows,
      rowIndex: _templateFooterRowStartIndex,
      cellIndex: 3,
      value: submittedTo ?? '',
    );
  }
}

String _labelValue(String label, String value) {
  final String trimmedValue = value.trim();
  if (trimmedValue.isEmpty) return label;
  return '$label $trimmedValue';
}

void _setRowCellText(
  List<XmlElement> rows, {
  required int rowIndex,
  required int cellIndex,
  required String value,
}) {
  final XmlElement row = rows[rowIndex];
  List<XmlElement> cells = row.findElements('tc', namespace: _wNs).toList();
  if (cells.isEmpty) {
    cells = row.findElements('tc').toList();
  }
  if (cellIndex < 0 || cellIndex >= cells.length) {
    throw StateError(
      'Template cell index out of range (row=$rowIndex cell=$cellIndex cells=${cells.length}).',
    );
  }
  final XmlElement cell = cells[cellIndex];

  List<XmlElement> texts = cell.findAllElements('t', namespace: _wNs).toList();
  if (texts.isEmpty) {
    texts = cell.findAllElements('t').toList();
  }
  if (texts.isEmpty) {
    // Fallback: create a minimal paragraph/run/text.
    cell.children.add(
      XmlElement(XmlName('p', 'w'), const <XmlAttribute>[], <XmlNode>[
        XmlElement(XmlName('r', 'w'), const <XmlAttribute>[], <XmlNode>[
          XmlElement(XmlName('t', 'w'), const <XmlAttribute>[], <XmlNode>[
            XmlText(value),
          ]),
        ]),
      ]),
    );
    return;
  }

  texts.first.children
    ..clear()
    ..add(XmlText(value));

  for (final XmlElement other in texts.skip(1)) {
    other.children
      ..clear()
      ..add(XmlText(''));
  }
}
