import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

const Set<int> _defaultMeetingWeekdays = <int>{
  DateTime.monday,
  DateTime.tuesday,
  DateTime.wednesday,
  DateTime.thursday,
  DateTime.friday,
  DateTime.saturday,
};

class GenerateReportPage extends StatefulWidget {
  const GenerateReportPage({super.key});

  static const String routeName = '/reports/generate';

  @override
  State<GenerateReportPage> createState() => _GenerateReportPageState();
}

class _GenerateReportPageState extends State<GenerateReportPage> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  bool _isLoadingClasses = true;
  bool _isLoadingPreview = false;
  bool _isPrintingReport = false;
  List<_ClassOption> _classes = <_ClassOption>[];
  String? _selectedClassId;
  DateTimeRange? _selectedRange;
  List<DateTime> _workingDays = <DateTime>[];
  List<_ReportRow> _previewRows = <_ReportRow>[];

  @override
  void initState() {
    super.initState();
    _loadClassOptions();
  }

  Future<void> _loadClassOptions() async {
    setState(() => _isLoadingClasses = true);
    try {
      final QuerySnapshot<Map<String, dynamic>> snapshot = await _firestore
          .collection('classes')
          .orderBy('subjectCode')
          .get();
        final List<_ClassOption> options = snapshot.docs
          .map(_ClassOption.fromDoc)
          .whereType<_ClassOption>()
          .toList();
      if (!mounted) return;
      setState(() {
        _classes = options;
        _isLoadingClasses = false;
        if (_classes.isEmpty) {
          _selectedClassId = null;
          _workingDays = <DateTime>[];
        } else {
            final bool selectionMissing = _selectedClassId == null ||
              !_classes.any((_ClassOption option) => option.id == _selectedClassId);
          if (selectionMissing) {
            _selectedClassId = _classes.first.id;
          }
          if (_selectedRange != null) {
            _workingDays =
                _expandMeetingDays(_selectedRange!, _resolveSelectedClass());
          }
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _isLoadingClasses = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to load classes: $error')),
      );
    }
  }

  Future<void> _pickDateRange() async {
    final DateTime now = DateTime.now();
    final DateTime today = DateTime(now.year, now.month, now.day);
    final DateTime firstDate = DateTime(now.year - 1);
    final DateTime lastDate = DateTime(now.year + 1);
    final DateTimeRange initial = _clampRangeToBounds(
      _sanitizeInitialRange(
        _selectedRange ??
            DateTimeRange(
              start: today.subtract(const Duration(days: 6)),
              end: today,
            ),
      ),
      firstDate,
      lastDate,
    );
    final DateTimeRange? picked = await _showMonthYearRangePicker(
      initialRange: initial,
      firstDate: firstDate,
      lastDate: lastDate,
    );
    if (picked == null) return;
    final _ClassOption? selectedClass = _resolveSelectedClass();
    final List<DateTime> weekdays = _expandMeetingDays(picked, selectedClass);
    if (weekdays.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select a range that includes a scheduled class day.')),
      );
      return;
    }
    if (!mounted) return;
    setState(() {
      _selectedRange = picked;
      _workingDays = weekdays;
    });
  }

  Future<DateTimeRange?> _showMonthYearRangePicker({
    required DateTimeRange initialRange,
    required DateTime firstDate,
    required DateTime lastDate,
  }) {
    return showDialog<DateTimeRange>(
      context: context,
      barrierDismissible: true,
      builder: (BuildContext context) {
        return Dialog(
          insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          child: _MonthYearRangePicker(
            initialRange: initialRange,
            firstDate: firstDate,
            lastDate: lastDate,
            selectableDayPredicate: _isSelectableDay,
          ),
        );
      },
    );
  }

  Future<void> _generatePreview() async {
    final _ClassOption? selectedClass = _resolveSelectedClass();
    if (selectedClass == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select a class first.')),
      );
      return;
    }
    final DateTimeRange? range = _selectedRange;
    if (range == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select a date range first.')),
      );
      return;
    }
    if (_workingDays.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pick days that include at least one class meeting.')),
      );
      return;
    }
    setState(() {
      _isLoadingPreview = true;
      _previewRows = <_ReportRow>[];
    });
    try {
      final List<_StudentRosterEntry> roster = await _fetchRoster(selectedClass);
      final Map<DateTime, Map<String, AttendanceMark>> matrix =
          await _fetchAttendanceMatrix(
        classId: selectedClass.id,
        range: range,
        dateKeys: _workingDays,
      );
      final DateTime today = _dayKey(DateTime.now());
      final List<_ReportRow> rows = roster
          .map((_StudentRosterEntry student) {
        final Map<DateTime, AttendanceMark> marks = <DateTime, AttendanceMark>{};
        for (final DateTime day in _workingDays) {
          final DateTime key = _dayKey(day);
          final AttendanceMark? mark = matrix[key]?[student.id];
          if (mark != null) {
            marks[key] = mark;
          } else if (key.isBefore(today)) {
            marks[key] = AttendanceMark.absent;
          }
        }
        final String courseYear = (student.courseYear?.isNotEmpty == true)
            ? student.courseYear!
            : selectedClass.courseYearLabel;
        return _ReportRow(
          studentId: student.id,
          studentName: student.displayName,
          courseYear: courseYear,
          marks: marks,
        );
      }).toList()
        ..sort((a, b) => a.studentName.compareTo(b.studentName));
      if (!mounted) return;
      setState(() {
        _previewRows = rows;
        _isLoadingPreview = false;
      });
      if (roster.isEmpty && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'No student profiles found for section ${selectedClass.sectionLabel}.',
            ),
          ),
        );
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _isLoadingPreview = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to build report: $error')),
      );
    }
  }

  Future<void> _printReport() async {
    final _ClassOption? selectedClass = _resolveSelectedClass();
    final DateTimeRange? range = _selectedRange;
    if (selectedClass == null || range == null || !_hasPrintableData) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Generate a preview before printing.')),
      );
      return;
    }
    if (_isPrintingReport) return;
    setState(() => _isPrintingReport = true);
    try {
      final pw.Document document = pw.Document();
      final List<List<DateTime>> dateChunks = _chunkDates(_workingDays, 10);
      if (dateChunks.isEmpty) {
        throw Exception('No class days available to print.');
      }
      for (int page = 0; page < dateChunks.length; page++) {
        final List<DateTime> chunk = dateChunks[page];
        document.addPage(
          pw.MultiPage(
            pageFormat: PdfPageFormat.a4.landscape,
            margin: const pw.EdgeInsets.all(24),
            build: (pw.Context context) => <pw.Widget>[
              _buildPdfHeader(selectedClass, range, page + 1, dateChunks.length),
              pw.SizedBox(height: 6),
              _buildPdfInstructionBlock(),
              pw.SizedBox(height: 10),
              _buildPdfTable(chunk),
            ],
          ),
        );
      }
      await Printing.layoutPdf(
        onLayout: (PdfPageFormat format) async => document.save(),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unable to generate printable report: $error')),
      );
    } finally {
      if (mounted) {
        setState(() => _isPrintingReport = false);
      }
    }
  }

  List<List<DateTime>> _chunkDates(List<DateTime> days, int size) {
    if (days.isEmpty) return <List<DateTime>>[];
    final List<List<DateTime>> chunks = <List<DateTime>>[];
    for (int i = 0; i < days.length; i += size) {
      final int end = math.min(i + size, days.length);
      chunks.add(days.sublist(i, end));
    }
    return chunks;
  }

  pw.Widget _buildPdfHeader(
    _ClassOption selectedClass,
    DateTimeRange range,
    int page,
    int totalPages,
  ) {
    return pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: <pw.Widget>[
        pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: <pw.Widget>[
            pw.Text(
              'Attendance Report',
              style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold),
            ),
            pw.Text('${selectedClass.subjectCode} - ${selectedClass.sectionLabel}',
                style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
            pw.Text('Course & Year: ${selectedClass.courseYearLabel}',
                style: const pw.TextStyle(fontSize: 11)),
            pw.Text(
              'Date Range: ${_formatDate(range.start)} - ${_formatDate(range.end)}',
              style: const pw.TextStyle(fontSize: 11),
            ),
          ],
        ),
        pw.Text(
          'Page $page of $totalPages',
          style: const pw.TextStyle(fontSize: 11),
        ),
      ],
    );
  }

  pw.Widget _buildPdfInstructionBlock() {
    return pw.Container(
      width: double.infinity,
      padding: const pw.EdgeInsets.symmetric(vertical: 4),
      child: pw.Text(
        'Indicate the date and put a checkmark if student is present.',
        style: pw.TextStyle(
          fontSize: 11,
          fontStyle: pw.FontStyle.italic,
          color: PdfColors.grey700,
        ),
      ),
    );
  }

  pw.Widget _buildPdfTable(List<DateTime> days) {
    final List<pw.TableRow> rows = <pw.TableRow>[
      pw.TableRow(
        decoration: const pw.BoxDecoration(color: PdfColors.grey200),
        children: <pw.Widget>[
          _pdfTableHeaderCell('No.'),
          _pdfTableHeaderCell('Name of Student', align: pw.TextAlign.left),
          _pdfTableHeaderCell('Course & Year', align: pw.TextAlign.left),
          ...days.map((DateTime day) => _pdfTableHeaderCell(_formatDate(day))),
        ],
      ),
    ];
    for (int index = 0; index < _previewRows.length; index++) {
      final _ReportRow row = _previewRows[index];
      rows.add(
        pw.TableRow(
          children: <pw.Widget>[
            _pdfTableCell('${index + 1}', align: pw.TextAlign.center),
            _pdfTableCell(row.studentName, align: pw.TextAlign.left),
            _pdfTableCell(row.courseYear, align: pw.TextAlign.left),
            ...days.map((DateTime day) {
              final AttendanceMark? mark = row.marks[_dayKey(day)];
              final String value = mark == null ? '' : _printSymbolForPdf(mark);
              return _pdfTableCell(value, align: pw.TextAlign.center);
            }),
          ],
        ),
      );
    }
    return pw.Table(
      border: pw.TableBorder.all(color: PdfColors.grey600, width: 0.5),
      defaultVerticalAlignment: pw.TableCellVerticalAlignment.middle,
      columnWidths: <int, pw.TableColumnWidth>{
        0: const pw.FixedColumnWidth(30),
        1: const pw.FlexColumnWidth(3),
        2: const pw.FlexColumnWidth(2),
      },
      children: rows,
    );
  }

  pw.Widget _pdfTableHeaderCell(String text, {pw.TextAlign align = pw.TextAlign.center}) {
    return pw.Container(
      padding: const pw.EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      alignment: align == pw.TextAlign.center
          ? pw.Alignment.center
          : pw.Alignment.centerLeft,
      child: pw.Text(
        text,
        textAlign: align,
        style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold),
      ),
    );
  }

  pw.Widget _pdfTableCell(String text, {pw.TextAlign align = pw.TextAlign.left}) {
    return pw.Container(
      padding: const pw.EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      alignment: align == pw.TextAlign.center
          ? pw.Alignment.center
          : pw.Alignment.centerLeft,
      child: pw.Text(
        text,
        textAlign: align,
        style: const pw.TextStyle(fontSize: 10),
      ),
    );
  }

  String _printSymbolForPdf(AttendanceMark mark) {
    switch (mark) {
      case AttendanceMark.present:
        return 'P';
      case AttendanceMark.absent:
        return 'A';
      case AttendanceMark.late:
        return 'L';
      case AttendanceMark.excused:
        return 'E';
    }
  }

  List<DateTime> _expandMeetingDays(DateTimeRange range, _ClassOption? classOption) {
    final Set<int> allowedWeekdays = _meetingWeekdaysFor(classOption);
    final List<DateTime> days = <DateTime>[];
    DateTime cursor = _dayKey(range.start);
    final DateTime rangeEnd = _dayKey(range.end);
    while (!cursor.isAfter(rangeEnd)) {
      if (allowedWeekdays.contains(cursor.weekday)) {
        days.add(cursor);
      }
      cursor = cursor.add(const Duration(days: 1));
    }
    return days;
  }

  Set<int> _meetingWeekdaysFor(_ClassOption? classOption) {
    final Set<int>? custom = classOption?.meetingWeekdays;
    if (custom == null || custom.isEmpty) {
      return _defaultMeetingWeekdays;
    }
    return custom;
  }

  DateTimeRange _clampRangeToBounds(
    DateTimeRange range,
    DateTime min,
    DateTime max,
  ) {
    DateTime start = range.start.isBefore(min) ? min : range.start;
    DateTime end = range.end.isAfter(max) ? max : range.end;
    if (start.isAfter(end)) {
      start = min;
      end = min;
    }
    return DateTimeRange(start: start, end: end);
  }

  DateTimeRange _sanitizeInitialRange(DateTimeRange range) {
    DateTime start = range.start;
    DateTime end = range.end;
    start = _nearestSelectableDay(start, forward: true);
    end = _nearestSelectableDay(end, forward: false);
    if (start.isAfter(end)) {
      start = _nearestSelectableDay(range.start, forward: true);
      end = start;
    }
    return DateTimeRange(start: start, end: end);
  }

  bool _isSelectableDay(DateTime day) => day.weekday != DateTime.sunday;

  DateTime _nearestSelectableDay(
    DateTime date, {
    required bool forward,
  }) {
    DateTime cursor = DateTime(date.year, date.month, date.day);
    int safety = 0;
    while (!_isSelectableDay(cursor) && safety < 7) {
      cursor = forward ? cursor.add(const Duration(days: 1)) : cursor.subtract(const Duration(days: 1));
      safety++;
    }
    return cursor;
  }

  _ClassOption? _resolveSelectedClass() => _findClassById(_selectedClassId);

  _ClassOption? _findClassById(String? classId) {
    if (_classes.isEmpty || classId == null) {
      return null;
    }
    for (final _ClassOption option in _classes) {
      if (option.id == classId) {
        return option;
      }
    }
    return null;
  }

  bool get _hasPrintableData => _previewRows.isNotEmpty && _workingDays.isNotEmpty;

  Future<List<_StudentRosterEntry>> _fetchRoster(
    _ClassOption selectedClass,
  ) async {
    final QuerySnapshot<Map<String, dynamic>> snapshot = await _firestore
        .collection('users')
        .where('role', isEqualTo: 'student')
        .where('section', isEqualTo: selectedClass.sectionLabel)
        .get();
    final List<_StudentRosterEntry> roster = snapshot.docs
        .map(_StudentRosterEntry.fromDoc)
        .whereType<_StudentRosterEntry>()
        .toList()
      ..sort((a, b) => a.displayName.compareTo(b.displayName));
    return roster;
  }

  Future<Map<DateTime, Map<String, AttendanceMark>>> _fetchAttendanceMatrix({
    required String classId,
    required DateTimeRange range,
    required List<DateTime> dateKeys,
  }) async {
    final Map<DateTime, Map<String, AttendanceMark>> matrix = <DateTime, Map<String, AttendanceMark>>{
      for (final DateTime key in dateKeys) _dayKey(key): <String, AttendanceMark>{},
    };
    final DateTime rangeStart = _dayKey(range.start);
    final DateTime rangeEndExclusive = _dayKey(range.end).add(const Duration(days: 1));
    final Query<Map<String, dynamic>> query = _firestore
        .collection('attendanceSessions')
        .where('classId', isEqualTo: classId)
        .where('startedAt', isGreaterThanOrEqualTo: Timestamp.fromDate(rangeStart))
        .where('startedAt', isLessThan: Timestamp.fromDate(rangeEndExclusive));
    final QuerySnapshot<Map<String, dynamic>> sessionsSnapshot = await query.get();
    final List<QueryDocumentSnapshot<Map<String, dynamic>>> sessions = sessionsSnapshot.docs;
    await Future.wait(sessions.map((QueryDocumentSnapshot<Map<String, dynamic>> doc) async {
      final Map<String, dynamic> data = doc.data();
      final Timestamp? startedAt = (data['startedAt'] as Timestamp?) ??
          (data['createdAt'] as Timestamp?);
      if (startedAt == null) {
        return;
      }
      final DateTime dayKey = _dayKey(startedAt.toDate());
      if (!matrix.containsKey(dayKey)) {
        return;
      }
      final QuerySnapshot<Map<String, dynamic>> attendeesSnapshot =
          await doc.reference.collection('attendees').get();
      final Map<String, AttendanceMark> dayMarks =
          matrix.putIfAbsent(dayKey, () => <String, AttendanceMark>{});
      for (final QueryDocumentSnapshot<Map<String, dynamic>> attendee in
          attendeesSnapshot.docs) {
        final Map<String, dynamic> attendeeData = attendee.data();
        final AttendanceMark? mark =
            _statusToMark(attendeeData['status'] as String?);
        if (mark != null) {
          dayMarks[attendee.id] = mark;
        }
      }
    }));
    return matrix;
  }

  AttendanceMark? _statusToMark(String? status) {
    if (status == null) {
      return null;
    }
    switch (status.toLowerCase()) {
      case 'present':
        return AttendanceMark.present;
      case 'late':
        return AttendanceMark.late;
      case 'absent':
        return AttendanceMark.absent;
      case 'excused':
        return AttendanceMark.excused;
      default:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Attendance Report Generator')),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async {
            await _loadClassOptions();
            if (_selectedRange != null && mounted) {
              final _ClassOption? selectedClass = _resolveSelectedClass();
              setState(() {
                _workingDays =
                    _expandMeetingDays(_selectedRange!, selectedClass);
              });
            }
          },
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final bool isWide = constraints.maxWidth >= 900;
              final EdgeInsets padding = EdgeInsets.symmetric(
                horizontal: isWide ? 48 : 20,
                vertical: 24,
              );
              return SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: padding,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Configure the report range, select a section, then review the roster before exporting.',
                      style: theme.textTheme.bodyLarge,
                    ),
                    const SizedBox(height: 24),
                    _buildFiltersCard(theme),
                    const SizedBox(height: 24),
                    _buildPreviewCard(theme),
                    const SizedBox(height: 24),
                    _buildLegend(theme),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildFiltersCard(ThemeData theme) {
    final _ClassOption selectedClass = _resolveSelectedClass() ??
        (_classes.isNotEmpty ? _classes.first : _ClassOption.empty());
    final String rangeLabel = _selectedRange == null
      ? 'Select date range'
      : '${_formatDate(_selectedRange!.start)} → ${_formatDate(_selectedRange!.end)}';
    final bool canPrint = _hasPrintableData && !_isPrintingReport;
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Filters',
              style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              value: _selectedClassId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Subject section'),
              items: _classes
                  .map(
                    (_ClassOption option) => DropdownMenuItem<String>(
                      value: option.id,
                      child: Text('${option.subjectCode} • ${option.sectionLabel}'),
                    ),
                  )
                  .toList(),
              onChanged: _isLoadingClasses
                  ? null
                  : (String? value) {
                      setState(() {
                        _selectedClassId = value;
                        if (_selectedRange != null) {
                          _workingDays = _selectedClassId == null
                              ? <DateTime>[]
                              : _expandMeetingDays(
                                  _selectedRange!,
                                  _resolveSelectedClass(),
                                );
                        }
                      });
                    },
            ),
            if (_isLoadingClasses)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: LinearProgressIndicator(),
              ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _pickDateRange,
              icon: const Icon(Icons.calendar_month_outlined),
              label: Text(rangeLabel),
            ),
            if (_workingDays.isNotEmpty) ...<Widget>[
              const SizedBox(height: 12),
              _buildSelectedRangeSummary(theme),
            ],
            const SizedBox(height: 20),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: <Widget>[
                FilledButton.icon(
                  onPressed: _isLoadingPreview ? null : _generatePreview,
                  icon: _isLoadingPreview
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.playlist_add_check),
                  label: Text(_isLoadingPreview ? 'Preparing preview...' : 'Preview roster'),
                ),
                OutlinedButton.icon(
                  onPressed: canPrint ? _printReport : null,
                  icon: _isPrintingReport
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.print_outlined),
                  label: Text(_isPrintingReport ? 'Preparing PDF...' : 'Print report'),
                ),
              ],
            ),
            if (_selectedClassId != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  'Course & Year: ${selectedClass.courseYearLabel}',
                  style: theme.textTheme.labelMedium,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSelectedRangeSummary(ThemeData theme) {
    if (_workingDays.isEmpty) {
      return const SizedBox.shrink();
    }
    final DateTime start = _workingDays.first;
    final DateTime end = _workingDays.last;
    final int totalDays = _workingDays.length;
    final ColorScheme colors = theme.colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.calendar_month, color: colors.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '${_formatDate(start)} → ${_formatDate(end)}',
                  style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
                Text(
                  '$totalDays class days selected',
                  style: theme.textTheme.labelMedium,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPreviewCard(ThemeData theme) {
    if (_isLoadingPreview) {
      return Card(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: const SizedBox(
          height: 220,
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }
    if (_previewRows.isEmpty || _workingDays.isEmpty) {
      return Card(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: SizedBox(
          width: double.infinity,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: <Widget>[
                Icon(Icons.grid_on, color: theme.colorScheme.primary),
                const SizedBox(height: 12),
                Text(
                  'Preview the table to see roster rows and date columns.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium,
                ),
              ],
            ),
          ),
        ),
      );
    }
    final List<DataColumn> columns = <DataColumn>[
      const DataColumn(label: Text('Name of Student')),
      const DataColumn(label: Text('Course & Year')),
      ..._workingDays.map(
        (DateTime day) => DataColumn(label: Text(_formatShortDate(day))),
      ),
    ];
    final List<DataRow> rows = _previewRows
        .map((_ReportRow row) => _buildRow(row, theme))
        .toList();
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.all(16),
        child: DataTable(columns: columns, rows: rows),
      ),
    );
  }

  DataRow _buildRow(_ReportRow row, ThemeData theme) {
    final List<DataCell> cells = <DataCell>[
      DataCell(Text(row.studentName)),
      DataCell(Text(row.courseYear)),
      ..._workingDays.map((DateTime day) {
        final AttendanceMark? mark = row.marks[_dayKey(day)];
        return DataCell(_buildMarkChip(mark, theme));
      }),
    ];
    return DataRow(cells: cells);
  }

  Widget _buildMarkChip(AttendanceMark? mark, ThemeData theme) {
    final String label = mark == null ? '' : mark.symbol;
    final ColorScheme colors = theme.colorScheme;
    final Color background;
    switch (mark) {
      case AttendanceMark.present:
        background = colors.primaryContainer;
      case AttendanceMark.absent:
        background = colors.errorContainer;
      case AttendanceMark.late:
        background = colors.tertiaryContainer;
      case AttendanceMark.excused:
        background = colors.secondaryContainer;
      case null:
        background = colors.surfaceVariant;
    }
    return Container(
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(label, style: theme.textTheme.labelMedium),
    );
  }

  Widget _buildLegend(ThemeData theme) {
    final List<_LegendEntry> entries = <_LegendEntry>[
      _LegendEntry('✓', 'Present'),
      _LegendEntry('A', 'Absent'),
      _LegendEntry('L', 'Late'),
      _LegendEntry('Exc', 'Excused'),
    ];
    return Wrap(
      spacing: 16,
      runSpacing: 12,
      children: entries
          .map((_LegendEntry entry) =>
              Chip(avatar: Text(entry.symbol), label: Text(entry.label)))
          .toList(),
    );
  }

  String _formatDate(DateTime date) {
    final DateTime normalized = _dayKey(date);
    return '${_monthLabel(normalized.month)} ${normalized.day}';
  }

  String _formatShortDate(DateTime date) {
    final DateTime normalized = _dayKey(date);
    return '${normalized.month}/${normalized.day}';
  }

  DateTime _dayKey(DateTime date) => DateTime(date.year, date.month, date.day);

  String _monthLabel(int month) {
    const List<String> months = <String>[
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return months[month - 1];
  }
}

class _ClassOption {
  const _ClassOption({
    required this.id,
    required this.subjectCode,
    required this.subjectName,
    required this.sectionLabel,
    required this.courseYearLabel,
    required this.termLabel,
    required this.meetingWeekdays,
  });

  final String id;
  final String subjectCode;
  final String subjectName;
  final String sectionLabel;
  final String courseYearLabel;
  final String termLabel;
  final Set<int> meetingWeekdays;

  static _ClassOption? fromDoc(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final Map<String, dynamic>? data = doc.data();
    if (data == null) return null;
    final String subjectCode = (data['subjectCode'] as String?) ?? 'N/A';
    final String subjectName = (data['subjectName'] as String?) ?? 'Untitled Subject';
    final String section = ((data['section'] as String?) ?? 'Section').trim();
    final String courseYear = ((data['courseYear'] as String?) ?? '').trim();
    final String term = (data['term'] as String?) ?? '';
    final List<dynamic> schedules = (data['schedules'] as List<dynamic>? ?? <dynamic>[]);
    final Set<int> meetingWeekdays = _extractMeetingWeekdays(schedules);
    return _ClassOption(
      id: doc.id,
      subjectCode: subjectCode,
      subjectName: subjectName,
      sectionLabel: section.isEmpty ? 'Section' : section,
      courseYearLabel: courseYear.isEmpty ? section : courseYear,
      termLabel: term,
      meetingWeekdays: meetingWeekdays,
    );
  }

  factory _ClassOption.empty() => const _ClassOption(
        id: 'placeholder-class',
        subjectCode: 'N/A',
        subjectName: 'No subject',
        sectionLabel: 'Section',
        courseYearLabel: '--',
        termLabel: '',
        meetingWeekdays: _defaultMeetingWeekdays,
      );

  static Set<int> _extractMeetingWeekdays(List<dynamic> schedules) {
    final Set<int> days = <int>{};
    for (final dynamic entry in schedules) {
      if (entry is! Map<String, dynamic>) {
        continue;
      }
      final String? rawDay = entry['day'] as String?;
      final int? weekday = _weekdayFromLabel(rawDay);
      if (weekday != null) {
        days.add(weekday);
      }
    }
    return days.isEmpty ? Set<int>.from(_defaultMeetingWeekdays) : days;
  }
}

int? _weekdayFromLabel(String? label) {
  if (label == null) {
    return null;
  }
  final String normalized = label.trim().toLowerCase();
  switch (normalized) {
    case 'monday':
    case 'mon':
      return DateTime.monday;
    case 'tuesday':
    case 'tue':
    case 'tues':
      return DateTime.tuesday;
    case 'wednesday':
    case 'wed':
      return DateTime.wednesday;
    case 'thursday':
    case 'thu':
    case 'thurs':
      return DateTime.thursday;
    case 'friday':
    case 'fri':
      return DateTime.friday;
    case 'saturday':
    case 'sat':
      return DateTime.saturday;
    case 'sunday':
    case 'sun':
      return DateTime.sunday;
    default:
      return null;
  }
}

class _StudentRosterEntry {
  const _StudentRosterEntry({
    required this.id,
    required this.displayName,
    this.courseYear,
  });

  final String id;
  final String displayName;
  final String? courseYear;

  static _StudentRosterEntry? fromDoc(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final Map<String, dynamic> data = doc.data();
    final String name = _resolveDisplayName(data, doc.id);
    if (name.isEmpty) {
      return null;
    }
    final String? section = (data['section'] as String?)?.trim();
    final String? courseYear = ((data['courseYear'] as String?) ?? section)?.trim();
    return _StudentRosterEntry(
      id: doc.id,
      displayName: name,
      courseYear: (courseYear == null || courseYear.isEmpty) ? null : courseYear,
    );
  }

  static String _resolveDisplayName(Map<String, dynamic> data, String fallbackId) {
    const List<String> keys = <String>[
      'displayName',
      'display_name',
      'Full Name',
      'fullName',
      'FullName',
      'fullname',
      'full_name',
      'name',
      'studentName',
      'student_name',
    ];
    for (final String key in keys) {
      final String? raw = (data[key] as String?)?.trim();
      if (raw != null && raw.isNotEmpty) {
        return raw;
      }
    }
    final int safeLength = fallbackId.isEmpty
        ? 0
        : fallbackId.length > 6
            ? 6
            : fallbackId.length;
    final String label = safeLength == 0
        ? fallbackId
        : fallbackId.substring(0, safeLength);
    return 'Student ${label.toUpperCase()}';
  }
}

class _ReportRow {
  const _ReportRow({
    required this.studentId,
    required this.studentName,
    required this.courseYear,
    required this.marks,
  });

  final String studentId;
  final String studentName;
  final String courseYear;
  final Map<DateTime, AttendanceMark> marks;
}

enum AttendanceMark { present, absent, late, excused }

extension on AttendanceMark {
  String get symbol {
    switch (this) {
      case AttendanceMark.present:
        return '✓';
      case AttendanceMark.absent:
        return 'A';
      case AttendanceMark.late:
        return 'L';
      case AttendanceMark.excused:
        return 'Exc';
    }
  }
}

class _LegendEntry {
  const _LegendEntry(this.symbol, this.label);

  final String symbol;
  final String label;
}

class _MonthYearRangePicker extends StatefulWidget {
  const _MonthYearRangePicker({
    required this.initialRange,
    required this.firstDate,
    required this.lastDate,
    required this.selectableDayPredicate,
  });

  final DateTimeRange initialRange;
  final DateTime firstDate;
  final DateTime lastDate;
  final bool Function(DateTime day) selectableDayPredicate;

  @override
  State<_MonthYearRangePicker> createState() => _MonthYearRangePickerState();
}

class _MonthYearRangePickerState extends State<_MonthYearRangePicker> {
  static const List<String> _monthLabels = <String>[
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];

  late int _displayMonth;
  late int _displayYear;
  DateTime? _rangeStart;
  DateTime? _rangeEnd;
  late final ScrollController _scrollController;

  List<int> get _yearOptions {
    final int startYear = widget.firstDate.year;
    final int endYear = widget.lastDate.year;
    return List<int>.generate(endYear - startYear + 1, (int i) => startYear + i);
  }

  @override
  void initState() {
    super.initState();
    final DateTime safeStart = _clampDate(widget.initialRange.start);
    final DateTime safeEnd = _clampDate(widget.initialRange.end);
    _rangeStart = safeStart;
    _rangeEnd = safeEnd;
    _displayMonth = safeStart.month;
    _displayYear = safeStart.year;
    _ensureDisplayMonthValid();
    _scrollController = ScrollController();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  DateTime _clampDate(DateTime date) {
    if (date.isBefore(widget.firstDate)) {
      return widget.firstDate;
    }
    if (date.isAfter(widget.lastDate)) {
      return widget.lastDate;
    }
    return DateTime(date.year, date.month, date.day);
  }

  void _ensureDisplayMonthValid() {
    final List<int> months = _monthsForYear(_displayYear);
    if (!months.contains(_displayMonth)) {
      _displayMonth = months.first;
    }
  }

  List<int> _monthsForYear(int year) {
    final int minMonth = year == widget.firstDate.year ? widget.firstDate.month : 1;
    final int maxMonth = year == widget.lastDate.year ? widget.lastDate.month : 12;
    return List<int>.generate(maxMonth - minMonth + 1, (int i) => minMonth + i);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<int> months = _monthsForYear(_displayYear);
    final DateTime monthAnchor = DateTime(_displayYear, _displayMonth, 1);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints dialogConstraints) {
        final double maxHeight = dialogConstraints.maxHeight.isFinite
            ? math.min(dialogConstraints.maxHeight * 0.9, 720)
            : 720;
        return ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: SizedBox(
            height: maxHeight,
            child: Scrollbar(
              controller: _scrollController,
              thumbVisibility: true,
              child: SingleChildScrollView(
                controller: _scrollController,
                physics: const ClampingScrollPhysics(),
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Jump to a month, pick the days you need, and confirm.',
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: DropdownButtonFormField<int>(
                            value: _displayMonth,
                            decoration: const InputDecoration(labelText: 'Month'),
                            items: months
                                .map(
                                  (int month) => DropdownMenuItem<int>(
                                    value: month,
                                    child: Text(_monthLabels[month - 1]),
                                  ),
                                )
                                .toList(),
                            onChanged: (int? value) {
                              if (value == null) return;
                              setState(() => _displayMonth = value);
                            },
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: DropdownButtonFormField<int>(
                            value: _displayYear,
                            decoration: const InputDecoration(labelText: 'Year'),
                            items: _yearOptions
                                .map(
                                  (int year) => DropdownMenuItem<int>(
                                    value: year,
                                    child: Text('$year'),
                                  ),
                                )
                                .toList(),
                            onChanged: (int? value) {
                              if (value == null) return;
                              setState(() {
                                _displayYear = value;
                                _ensureDisplayMonthValid();
                              });
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    _WeekdayHeader(theme: theme),
                    const SizedBox(height: 8),
                    _buildCalendarGrid(theme, monthAnchor),
                    const SizedBox(height: 16),
                    Text(
                      _selectionLabel,
                      style: theme.textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: <Widget>[
                        TextButton(
                          onPressed: () => setState(() {
                            _rangeStart = null;
                            _rangeEnd = null;
                          }),
                          child: const Text('Clear selection'),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: () => Navigator.of(context).maybePop(),
                          child: const Text('Cancel'),
                        ),
                        const SizedBox(width: 12),
                        FilledButton(
                          onPressed: _rangeStart == null
                              ? null
                              : () {
                                  final DateTimeRange range = DateTimeRange(
                                    start: _rangeStart!,
                                    end: _rangeEnd ?? _rangeStart!,
                                  );
                                  Navigator.of(context).pop(range);
                                },
                          child: const Text('Use range'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildCalendarGrid(ThemeData theme, DateTime anchor) {
    final int daysInMonth = DateTime(anchor.year, anchor.month + 1, 0).day;
    final int leadingEmpty = (DateTime(anchor.year, anchor.month, 1).weekday + 6) % 7;
    final int totalCells = leadingEmpty + daysInMonth;
    final int trailingEmpty = totalCells % 7 == 0 ? 0 : 7 - (totalCells % 7);
    final int itemCount = totalCells + trailingEmpty;
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 7,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: itemCount,
      itemBuilder: (BuildContext context, int index) {
        if (index < leadingEmpty || index >= leadingEmpty + daysInMonth) {
          return const SizedBox.shrink();
        }
        final int dayNumber = index - leadingEmpty + 1;
        final DateTime day = DateTime(anchor.year, anchor.month, dayNumber);
        return _buildDayCell(theme, day, dayNumber);
      },
    );
  }

  Widget _buildDayCell(ThemeData theme, DateTime day, int dayNumber) {
    final bool withinBounds =
        !day.isBefore(widget.firstDate) && !day.isAfter(widget.lastDate);
    final bool selectable =
        withinBounds && widget.selectableDayPredicate(day);
    final bool isStart = _rangeStart != null && _isSameDay(day, _rangeStart!);
    final bool isEnd = _rangeEnd != null && _isSameDay(day, _rangeEnd!);
    final bool hasBoth = _rangeStart != null && _rangeEnd != null;
    final bool inBetween = hasBoth && !day.isBefore(_rangeStart!) && !day.isAfter(_rangeEnd!);

    final ColorScheme colors = theme.colorScheme;
    Color background;
    Color foreground;
    if (isStart || isEnd) {
      background = colors.primary;
      foreground = colors.onPrimary;
    } else if (inBetween) {
      background = colors.primaryContainer;
      foreground = colors.onPrimaryContainer;
    } else {
      background = selectable ? colors.surfaceVariant : colors.surface;
      foreground = selectable ? theme.textTheme.bodyMedium?.color ?? colors.onSurface : theme.disabledColor;
    }

    return GestureDetector(
      onTap: selectable ? () => _handleDayTap(day) : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(10),
          border: isStart || isEnd
              ? Border.all(color: colors.primary, width: 1.5)
              : null,
        ),
        alignment: Alignment.center,
        child: Text(
          '$dayNumber',
          style: theme.textTheme.bodyMedium?.copyWith(color: foreground),
        ),
      ),
    );
  }

  void _handleDayTap(DateTime day) {
    setState(() {
      if (_rangeStart == null || (_rangeStart != null && _rangeEnd != null)) {
        _rangeStart = day;
        _rangeEnd = null;
      } else {
        if (day.isBefore(_rangeStart!)) {
          _rangeEnd = _rangeStart;
          _rangeStart = day;
        } else {
          _rangeEnd = day;
        }
      }
    });
  }

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  String get _selectionLabel {
    if (_rangeStart == null) {
      return 'No dates selected yet.';
    }
    final DateTimeRange previewRange = DateTimeRange(
      start: _rangeStart!,
      end: _rangeEnd ?? _rangeStart!,
    );
    if (_isSameDay(previewRange.start, previewRange.end)) {
      return 'Selected: ${_format(previewRange.start)}';
    }
    return 'Selected: ${_format(previewRange.start)} → ${_format(previewRange.end)}';
  }

  String _format(DateTime date) {
    final String month = _monthLabels[date.month - 1].substring(0, 3);
    return '$month ${date.day}, ${date.year}';
  }
}

class _WeekdayHeader extends StatelessWidget {
  const _WeekdayHeader({required this.theme});

  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    const List<String> labels = <String>['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: labels
          .map((String label) => Expanded(
                child: Center(
                  child: Text(
                    label,
                    style: theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
              ))
          .toList(),
    );
  }
}
