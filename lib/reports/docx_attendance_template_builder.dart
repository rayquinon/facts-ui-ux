import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:docx_template_fork/docx_template_fork.dart';
import 'package:xml/xml.dart';

import 'attendance_mark.dart';
import 'docx_attendance_builder.dart'
    show DocxAttendanceHeader, DocxAttendanceRow;

String _markSymbol(AttendanceMark mark) {
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

Uint8List _normalizeTemplateForDocxTemplate(Uint8List templateBytes) {
  // Word templates can contain Content Controls (SDT) whose <w:sdtContent/>
  // is empty, or whose content has no <w:r><w:t>. `docx_template_fork`'s
  // TextView looks for the first <w:r> descendant and then updates its <w:t>.
  // If there is no run/text node, the replacement becomes a no-op.
  final Archive input = ZipDecoder().decodeBytes(templateBytes);
  final Archive output = Archive();

  XmlElement wEl(
    String local, [
    List<XmlAttribute> attrs = const [],
    List<XmlNode> children = const [],
  ]) {
    return XmlElement(XmlName(local, 'w'), attrs, children);
  }

  XmlElement? firstChild(XmlElement parent, String localName) {
    for (final XmlNode n in parent.children) {
      if (n is XmlElement && n.name.local == localName) {
        return n;
      }
    }
    return null;
  }

  XmlAttribute? attrByLocal(XmlElement el, String localName) {
    for (final XmlAttribute a in el.attributes) {
      if (a.name.local == localName) {
        return a;
      }
    }
    return null;
  }

  String? aliasValue(XmlElement sdtPr) {
    final XmlElement? aliasEl = firstChild(sdtPr, 'alias');
    return aliasEl == null ? null : attrByLocal(aliasEl, 'val')?.value;
  }

  bool isDateAlias(String? alias) {
    if (alias == null) return false;
    if (!alias.startsWith('date')) return false;
    final String suffix = alias.substring(4);
    if (suffix.length != 2) return false;
    final int? n = int.tryParse(suffix);
    return n != null && n >= 1 && n <= 13;
  }

  bool isMarkAlias(String? alias) {
    if (alias == null) return false;
    if (alias.length != 3) return false;
    final String prefix = alias.substring(0, 1);
    if (prefix != 'd' && prefix != 'm') return false;
    final int? n = int.tryParse(alias.substring(1));
    return n != null && n >= 1 && n <= 13;
  }

  void ensureCellVerticalCenter(XmlElement sdtContent) {
    // Many SDTs in the template wrap a table cell (<w:tc>). Make sure the cell
    // vertically centers its content.
    XmlElement? tc;
    for (final XmlNode n in sdtContent.descendants) {
      if (n is XmlElement && n.name.local == 'tc') {
        tc = n;
        break;
      }
    }
    if (tc == null) return;

    XmlElement? tcPr = firstChild(tc, 'tcPr');
    tcPr ??= wEl('tcPr');
    if (firstChild(tc, 'tcPr') == null) {
      tc.children.insert(0, tcPr);
    }

    XmlElement? vAlign = firstChild(tcPr, 'vAlign');
    vAlign ??= wEl('vAlign', [XmlAttribute(XmlName('val', 'w'), 'center')]);
    if (firstChild(tcPr, 'vAlign') == null) {
      tcPr.children.add(vAlign);
    } else {
      final XmlAttribute? existing = attrByLocal(vAlign, 'val');
      if (existing != null) {
        vAlign.attributes.remove(existing);
      }
      vAlign.attributes.add(XmlAttribute(XmlName('val', 'w'), 'center'));
    }
  }

  void ensureParagraphLeftAlign(XmlElement sdtContent) {
    // Ensure the paragraph inside the SDT is left-aligned.
    XmlElement? p;
    for (final XmlNode n in sdtContent.descendants) {
      if (n is XmlElement && n.name.local == 'p') {
        p = n;
        break;
      }
    }
    if (p == null) return;

    XmlElement? pPr = firstChild(p, 'pPr');
    pPr ??= wEl('pPr');
    if (firstChild(p, 'pPr') == null) {
      p.children.insert(0, pPr);
    }

    XmlElement? jc = firstChild(pPr, 'jc');
    jc ??= wEl('jc', [XmlAttribute(XmlName('val', 'w'), 'left')]);
    if (firstChild(pPr, 'jc') == null) {
      pPr.children.add(jc);
    } else {
      final XmlAttribute? existing = attrByLocal(jc, 'val');
      if (existing != null) {
        jc.attributes.remove(existing);
      }
      jc.attributes.add(XmlAttribute(XmlName('val', 'w'), 'left'));
    }
  }

  void ensureExactStudentRowHeight(XmlDocument doc, {required int twips}) {
    // 0.6cm ≈ 340 twips (twentieths of a point are *not* used here).
    // This targets the template row inside the `students` repeating section.
    final List<XmlElement> sdts = doc
        .descendants
        .whereType<XmlElement>()
        .where((e) => e.name.local == 'sdt')
        .toList(growable: false);

    for (final XmlElement sdt in sdts) {
      final XmlElement? sdtPr = firstChild(sdt, 'sdtPr');
      final XmlElement? sdtContent = firstChild(sdt, 'sdtContent');
      if (sdtPr == null || sdtContent == null) continue;

      final String? tagVal =
          attrByLocal(firstChild(sdtPr, 'tag') ?? wEl('tag'), 'val')?.value;
      final String? alias = aliasValue(sdtPr);
      if (tagVal != 'table' || alias != 'students') continue;

      // In this template the row is directly under sdtContent.
      final List<XmlElement> rows = sdtContent.children
          .whereType<XmlElement>()
          .where((e) => e.name.local == 'tr')
          .toList();
      if (rows.isEmpty) continue;

      for (final XmlElement tr in rows) {
        XmlElement? trPr = firstChild(tr, 'trPr');
        trPr ??= wEl('trPr');
        if (firstChild(tr, 'trPr') == null) {
          tr.children.insert(0, trPr);
        }

        XmlElement? trHeight = firstChild(trPr, 'trHeight');
        trHeight ??= wEl(
          'trHeight',
          [
            XmlAttribute(XmlName('val', 'w'), twips.toString()),
            XmlAttribute(XmlName('hRule', 'w'), 'exact'),
          ],
        );
        if (firstChild(trPr, 'trHeight') == null) {
          trPr.children.add(trHeight);
        } else {
          // Replace attributes to enforce exact height.
          trHeight.attributes
            ..removeWhere((a) => a.name.local == 'val' || a.name.local == 'hRule')
            ..add(XmlAttribute(XmlName('val', 'w'), twips.toString()))
            ..add(XmlAttribute(XmlName('hRule', 'w'), 'exact'));
        }
      }
    }
  }

  void ensureSmallFontOnFirstRun(XmlElement parent, {required int halfPoints}) {
    XmlElement? firstRun;
    for (final XmlNode n in parent.descendants) {
      if (n is XmlElement && n.name.local == 'r') {
        firstRun = n;
        break;
      }
    }
    if (firstRun == null) return;

    XmlElement? rPr;
    for (final XmlNode n in firstRun.children) {
      if (n is XmlElement && n.name.local == 'rPr') {
        rPr = n;
        break;
      }
    }
    final XmlElement runProps = rPr ?? wEl('rPr');
    if (!firstRun.children.contains(runProps)) {
      // Keep rPr at the start of the run.
      firstRun.children.insert(0, runProps);
    }

    void upsertSize(String localName) {
      XmlElement? el;
      for (final XmlNode n in runProps.children) {
        if (n is XmlElement && n.name.local == localName) {
          el = n;
          break;
        }
      }
      final XmlAttribute attr = XmlAttribute(
        XmlName('val', 'w'),
        halfPoints.toString(),
      );
      if (el == null) {
        runProps.children.add(wEl(localName, [attr]));
      } else {
        final XmlAttribute? existing = attrByLocal(el, 'val');
        if (existing != null) {
          el.attributes.remove(existing);
        }
        el.attributes.add(attr);
      }
    }

    // Word uses half-points: 18 => 9pt, 16 => 8pt, etc.
    upsertSize('sz');
    upsertSize('szCs');
  }

  void unwrapRepeatingSectionItemSdts(XmlDocument doc) {
    // Word "Repeating Section" controls wrap the repeated row in an inner SDT
    // that often has no <w:tag> and no <w:alias>, but contains
    // <w15:repeatingSectionItem/>. `docx_template_fork` stops traversing when it
    // encounters an untagged <w:sdt>, so nested placeholders become invisible.
    //
    // Normalize by unwrapping these wrapper SDTs and splicing their
    // <w:sdtContent> children into the parent.
    final List<XmlElement> sdts = doc
        .descendants
        .whereType<XmlElement>()
        .where((e) => e.name.local == 'sdt')
        .toList(growable: false);

    for (final XmlElement sdt in sdts) {
      final XmlElement? sdtPr = firstChild(sdt, 'sdtPr');
      final XmlElement? sdtContent = firstChild(sdt, 'sdtContent');
      if (sdtPr == null || sdtContent == null) continue;

      final bool isRepeatingItem = sdtPr.descendants
          .whereType<XmlElement>()
          .any((e) => e.name.local == 'repeatingSectionItem');
      if (!isRepeatingItem) continue;

      final XmlNode? parent = sdt.parent;
      if (parent is! XmlElement) continue;

      final int index = parent.children.indexOf(sdt);
      if (index < 0) continue;

      // Detach nodes from <w:sdtContent> before inserting elsewhere.
      final List<XmlNode> moved = <XmlNode>[];
      while (sdtContent.children.isNotEmpty) {
        moved.add(sdtContent.children.removeAt(0));
      }

      parent.children.removeAt(index);
      parent.children.insertAll(index, moved);
    }
  }

  void ensureRunText(XmlElement parent) {
    final hasRun = parent.descendants
        .whereType<XmlElement>()
        .any((e) => e.name.local == 'r');
    if (hasRun) {
      // Ensure at least one run has a direct <w:t> child (TextView requires it).
      XmlElement? firstRun;
      for (final XmlNode n in parent.descendants) {
        if (n is XmlElement && n.name.local == 'r') {
          firstRun = n;
          break;
        }
      }
      if (firstRun == null) return;

      bool hasT = false;
      for (final XmlNode n in firstRun.children) {
        if (n is XmlElement && n.name.local == 't') {
          hasT = true;
          break;
        }
      }
      if (!hasT) {
        firstRun.children.add(
          wEl(
            't',
            [XmlAttribute(XmlName('space', 'xml'), 'preserve')],
            [XmlText(' ')],
          ),
        );
      }
      return;
    }

    // Prefer inserting into the first paragraph, else fall back to sdtContent.
    XmlElement? firstParagraph;
    for (final XmlNode n in parent.descendants) {
      if (n is XmlElement && n.name.local == 'p') {
        firstParagraph = n;
        break;
      }
    }

    final run = wEl('r', const [], [
      wEl(
        't',
        [XmlAttribute(XmlName('space', 'xml'), 'preserve')],
        [XmlText(' ')],
      ),
    ]);

    if (firstParagraph != null) {
      firstParagraph.children.add(run);
    } else {
      parent.children.add(run);
    }
  }

  for (final ArchiveFile file in input.files.cast<ArchiveFile>()) {
    final String name = file.name;
    if (name.startsWith('word/') && name.endsWith('.xml')) {
      final List<int> rawBytes = file.content as List<int>;

      final String xml = utf8.decode(rawBytes, allowMalformed: true);
      // The template was authored with "Plain Text" content controls
      // (<w:text/>). Normalize to "Rich Text" controls (<w:richText/>).
      final String normalized = xml.replaceAll('<w:text/>', '<w:richText/>');

      final XmlDocument doc = XmlDocument.parse(normalized);

      unwrapRepeatingSectionItemSdts(doc);

      // Enforce layout tweaks requested for the filled template.
      ensureExactStudentRowHeight(doc, twips: 340);

      for (final XmlElement sdt in doc
          .descendants
          .whereType<XmlElement>()
          .where((e) => e.name.local == 'sdt')) {
        final XmlElement? sdtPr = firstChild(sdt, 'sdtPr');
        final XmlElement? sdtContent = firstChild(sdt, 'sdtContent');
        if (sdtPr == null || sdtContent == null) {
          continue;
        }

        final XmlElement? tagEl = firstChild(sdtPr, 'tag');
        final String? tagVal =
            tagEl == null ? null : attrByLocal(tagEl, 'val')?.value;
        if (tagVal != 'text') {
          continue;
        }

        ensureRunText(sdtContent);

        final String? alias = aliasValue(sdtPr);
        if (isDateAlias(alias)) {
          // Make date headers smaller without affecting other fields.
          ensureSmallFontOnFirstRun(sdtContent, halfPoints: 18);
          ensureCellVerticalCenter(sdtContent);
          ensureParagraphLeftAlign(sdtContent);
        } else if (isMarkAlias(alias)) {
          ensureCellVerticalCenter(sdtContent);
          ensureParagraphLeftAlign(sdtContent);
        }
      }

      final String patched = doc.toXmlString(pretty: false);

      final List<int> outBytes = utf8.encode(patched);
      output.addFile(ArchiveFile(name, outBytes.length, outBytes));
    } else {
      output.addFile(file);
    }
  }

  final List<int> zipped = ZipEncoder().encode(output);
  return Uint8List.fromList(zipped);
}

/// Builds an attendance DOCX using Word **content controls** (Developer tab),
/// powered by the `docx_template` package.
///
/// This approach keeps the original template styling/layout exactly as authored
/// in Word, because we only fill content controls and repeat a tagged table row.
///
/// Template requirements (content control properties):
/// - Header fields: tag=`text`
///   - title: `officeUnit`, `subject`, `classSchedule`, `courseCode`, `room`
/// - Template meta fields (top-right block): tag=`text`
///   - title: `documentCodeNo`, `revisionNo`, `effectiveDate`
/// - Date header fields: tag=`text`
///   - title: `date01`..`date13`
/// - Footer fields: tag=`text`
///   - title: `checkedBy`, `submittedTo`
/// - Student row: tag=`table` title=`students`
///   - inside the row: tag=`text` titles:
///     `no`, `studentName`, `courseYear`, and attendance marks.
///
/// Attendance marks can be either:
/// - `m01`..`m13` (recommended), or
/// - `d01`..`d13` (supported for compatibility with existing templates)
///
/// Notes:
/// - This builder supports up to 13 session days per exported DOCX.
///   If you need more, export by smaller ranges or we can extend the template
///   to support paging.
Future<Uint8List> buildAttendanceDocxFromContentControls({
  required Uint8List templateDocxBytes,
  required DocxAttendanceHeader header,
  required List<DateTime> sessionDays,
  required List<DocxAttendanceRow> students,
  String? checkedBy,
  String? submittedTo,
}) async {
  const int maxDays = 13;
  if (sessionDays.length > maxDays) {
    throw StateError(
      'Template supports up to $maxDays session days per export. '
      'Selected range contains ${sessionDays.length} sessions.',
    );
  }

  // On Flutter Web, asset bytes may be backed by an unmodifiable view.
  // `docx_template_fork` updates the underlying ZIP archive in-place, so ensure
  // the byte list is mutable.
  final Uint8List mutableTemplate = Uint8List.fromList(templateDocxBytes);
  final Uint8List normalizedTemplate = _normalizeTemplateForDocxTemplate(
    mutableTemplate,
  );
  final DocxTemplate docx = await DocxTemplate.fromBytes(normalizedTemplate);

  final Content content = Content();
  content
    ..add(TextContent('officeUnit', header.officeOrUnit))
    ..add(TextContent('subject', header.subject))
    ..add(TextContent('classSchedule', header.classSchedule))
    ..add(TextContent('courseCode', header.courseCode))
    ..add(TextContent('room', header.room))
    ..add(TextContent('documentCodeNo', (header.documentCodeNo ?? '').trim()))
    ..add(TextContent('revisionNo', (header.revisionNo ?? '').trim()))
    ..add(TextContent('effectiveDate', (header.effectiveDate ?? '').trim()))
    ..add(TextContent('checkedBy', (checkedBy ?? '').trim()))
    ..add(TextContent('submittedTo', (submittedTo ?? '').trim()));

  for (int i = 0; i < maxDays; i++) {
    final String key = 'date${(i + 1).toString().padLeft(2, '0')}';
    final String value = i < sessionDays.length
        ? '${sessionDays[i].month}/${sessionDays[i].day}/${(sessionDays[i].year % 100).toString().padLeft(2, '0')}'
        : '';
    content.add(TextContent(key, value));
  }

  final List<RowContent> tableRows = <RowContent>[];
  for (int i = 0; i < students.length; i++) {
    final DocxAttendanceRow row = students[i];
    final RowContent rowContent = RowContent();
    rowContent
      ..add(TextContent('no', (i + 1).toString()))
      ..add(TextContent('studentName', row.studentName))
      ..add(TextContent('courseYear', row.courseYear));

    for (int d = 0; d < maxDays; d++) {
      final String index = (d + 1).toString().padLeft(2, '0');
      final String keyM = 'm$index';
      final String keyD = 'd$index';
      String markText = '';
      if (d < sessionDays.length) {
        final DateTime dayKey = DateTime(
          sessionDays[d].year,
          sessionDays[d].month,
          sessionDays[d].day,
        );
        final AttendanceMark? mark = row.marksByDay[dayKey];
        markText = mark == null ? '' : _markSymbol(mark);
      }
      // Write both keys so the template can use either naming convention.
      rowContent
        ..add(TextContent(keyM, markText))
        ..add(TextContent(keyD, markText));
    }

    tableRows.add(rowContent);
  }

  final TableContent table = TableContent('students', tableRows);
  content.add(table);

  final List<int>? out = await docx.generate(
    content,
    tagPolicy: TagPolicy.removeAll,
  );
  if (out == null) {
    throw StateError('Failed to generate DOCX from template controls.');
  }
  return Uint8List.fromList(out);
}
