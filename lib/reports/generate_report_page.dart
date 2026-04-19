import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'attendance_mark.dart';
import 'attendance_report_template_meta.dart';
import 'docx_attendance_builder.dart';
import 'docx_attendance_template_builder.dart';
import 'save_bytes.dart';
import '../services/attendance_calendar_service.dart';
import '../services/user_role_service.dart';

const Set<int> _defaultMeetingWeekdays = <int>{
  DateTime.monday,
  DateTime.tuesday,
  DateTime.wednesday,
  DateTime.thursday,
  DateTime.friday,
  DateTime.saturday,
};

int _compareNamesAsc(String a, String b) {
  final String aa = a.trim().toLowerCase();
  final String bb = b.trim().toLowerCase();
  final int cmp = aa.compareTo(bb);
  if (cmp != 0) return cmp;
  return a.compareTo(b);
}

class GenerateReportPage extends StatefulWidget {
  const GenerateReportPage({super.key});

  static const String routeName = '/reports/generate';

  @override
  State<GenerateReportPage> createState() => _GenerateReportPageState();
}

class _GenerateReportPageState extends State<GenerateReportPage> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  bool _isLoadingClasses = true;
  bool _isLoadingPreview = false;
  bool _isExportingDocx = false;
  bool _isLoadingInstructors = false;
  bool _isAdminFlow = false;
  List<_InstructorOption> _instructors = <_InstructorOption>[];
  String? _selectedInstructorId;
  String? _selectedSubjectKey;
  List<_ClassOption> _classes = <_ClassOption>[];
  String? _selectedSectionLabel;
  String? _selectedClassId;
  DateTimeRange? _selectedRange;
  List<DateTime> _workingDays = <DateTime>[];
  List<_ReportRow> _previewRows = <_ReportRow>[];

  List<String> _availableSections() {
    final Set<String> set = <String>{};
    for (final _ClassOption option in _classes) {
      final String value = option.sectionLabel.trim();
      if (value.isNotEmpty) set.add(value);
    }
    final List<String> sections = set.toList()..sort();
    return sections;
  }

  List<_ClassOption> _classesForSection(String? sectionLabel) {
    final String section = (sectionLabel ?? '').trim();
    if (section.isEmpty) return <_ClassOption>[];
    return _classes.where((c) => c.sectionLabel.trim() == section).toList()
      ..sort((a, b) {
        final int codeCmp = a.subjectCode.compareTo(b.subjectCode);
        if (codeCmp != 0) return codeCmp;
        final int nameCmp = a.subjectName.compareTo(b.subjectName);
        if (nameCmp != 0) return nameCmp;
        return a.termLabel.compareTo(b.termLabel);
      });
  }

  List<_SubjectOption> _subjectsForAdmin() {
    final Map<String, _SubjectOption> map = <String, _SubjectOption>{};
    for (final _ClassOption option in _classes) {
      final String key = option.subjectKey;
      map.putIfAbsent(
        key,
        () => _SubjectOption(
          key: key,
          subjectCode: option.subjectCode,
          subjectName: option.subjectName,
        ),
      );
    }
    final List<_SubjectOption> subjects = map.values.toList()
      ..sort((a, b) {
        final int codeCmp = a.subjectCode.compareTo(b.subjectCode);
        if (codeCmp != 0) return codeCmp;
        return a.subjectName.compareTo(b.subjectName);
      });
    return subjects;
  }

  List<_ClassOption> _classesForSubject(String? subjectKey) {
    final String key = (subjectKey ?? '').trim();
    if (key.isEmpty) return <_ClassOption>[];
    return _classes.where((c) => c.subjectKey == key).toList()..sort((a, b) {
      final int sectionCmp = a.sectionLabel.compareTo(b.sectionLabel);
      if (sectionCmp != 0) return sectionCmp;
      return a.termLabel.compareTo(b.termLabel);
    });
  }

  @override
  void initState() {
    super.initState();
    _initAccessAndLoad();
  }

  Future<void> _initAccessAndLoad() async {
    final String? uid = _auth.currentUser?.uid;
    final String? role = await UserRoleService.fetchRoleByUid(uid);
    if (!mounted) return;

    final bool isAdmin = (role ?? '').toLowerCase() == 'admin';
    setState(() {
      _isAdminFlow = isAdmin;
      _selectedInstructorId = isAdmin ? null : uid;
    });

    if (isAdmin) {
      await _loadInstructors();
    } else {
      await _loadClassOptions();
    }
  }

  Future<void> _loadInstructors() async {
    setState(() => _isLoadingInstructors = true);
    try {
      final QuerySnapshot<Map<String, dynamic>> snapshot = await _firestore
          .collection('users')
          .where('role', isEqualTo: 'instructor')
          .get();

      final List<_InstructorOption> instructors =
          snapshot.docs
              .map(_InstructorOption.fromDoc)
              .whereType<_InstructorOption>()
              .toList()
            ..sort((a, b) => a.displayName.compareTo(b.displayName));

      if (!mounted) return;
      setState(() {
        _instructors = instructors;
        _selectedInstructorId =
            (_selectedInstructorId != null &&
                _instructors.any((i) => i.uid == _selectedInstructorId))
            ? _selectedInstructorId
            : (_instructors.isNotEmpty ? _instructors.first.uid : null);
        _isLoadingInstructors = false;
      });

      await _loadClassOptions();
    } catch (error) {
      if (!mounted) return;
      setState(() => _isLoadingInstructors = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to load instructors: $error')),
      );
    }
  }

  Future<void> _loadClassOptions() async {
    setState(() => _isLoadingClasses = true);
    try {
      final String instructorId = (_selectedInstructorId ?? '').trim();
      if (instructorId.isEmpty) {
        if (!mounted) return;
        setState(() {
          _classes = <_ClassOption>[];
          _isLoadingClasses = false;
          _selectedSectionLabel = null;
          _selectedSubjectKey = null;
          _selectedClassId = null;
          _workingDays = <DateTime>[];
          _previewRows = <_ReportRow>[];
        });
        return;
      }

      final QuerySnapshot<Map<String, dynamic>> snapshot = await _firestore
          .collection('classes')
          .where('instructorId', isEqualTo: instructorId)
          .get();
      final List<_ClassOption> options = snapshot.docs
          .map(_ClassOption.fromDoc)
          .whereType<_ClassOption>()
          .toList();
      if (!mounted) return;
      setState(() {
        _classes = options
          ..sort((a, b) {
            final int codeCmp = a.subjectCode.compareTo(b.subjectCode);
            if (codeCmp != 0) return codeCmp;
            final int sectionCmp = a.sectionLabel.compareTo(b.sectionLabel);
            if (sectionCmp != 0) return sectionCmp;
            return a.termLabel.compareTo(b.termLabel);
          });
        _isLoadingClasses = false;
        if (_classes.isEmpty) {
          _selectedSectionLabel = null;
          _selectedSubjectKey = null;
          _selectedClassId = null;
          _workingDays = <DateTime>[];
          _previewRows = <_ReportRow>[];
        } else {
          if (_isAdminFlow) {
            final List<_SubjectOption> subjects = _subjectsForAdmin();
            final bool subjectValid =
                _selectedSubjectKey != null &&
                subjects.any((s) => s.key == _selectedSubjectKey);
            _selectedSubjectKey = subjectValid
                ? _selectedSubjectKey
                : (subjects.isNotEmpty ? subjects.first.key : null);

            final List<_ClassOption> classesForSubject = _classesForSubject(
              _selectedSubjectKey,
            );
            final bool selectedClassValid =
                _selectedClassId != null &&
                classesForSubject.any((c) => c.id == _selectedClassId);
            _selectedClassId = selectedClassValid
                ? _selectedClassId
                : (classesForSubject.isNotEmpty
                      ? classesForSubject.first.id
                      : null);
          } else {
            final List<String> sections = _availableSections();
            final _ClassOption? previouslySelectedClass = _findClassById(
              _selectedClassId,
            );
            final String? inferredSection =
                previouslySelectedClass?.sectionLabel;
            final String? candidateSection =
                (_selectedSectionLabel != null &&
                    sections.contains(_selectedSectionLabel))
                ? _selectedSectionLabel
                : (inferredSection != null &&
                      sections.contains(inferredSection))
                ? inferredSection
                : (sections.isNotEmpty ? sections.first : null);
            _selectedSectionLabel = candidateSection;

            final List<_ClassOption> classesInSection = _classesForSection(
              _selectedSectionLabel,
            );
            final bool selectedClassValid =
                _selectedClassId != null &&
                classesInSection.any((c) => c.id == _selectedClassId);
            _selectedClassId = selectedClassValid
                ? _selectedClassId
                : (classesInSection.isNotEmpty
                      ? classesInSection.first.id
                      : null);
          }

          _previewRows = <_ReportRow>[];

          if (_selectedRange != null) {
            _workingDays = _expandMeetingDays(
              _selectedRange!,
              _resolveSelectedClass(),
            );
          }
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _isLoadingClasses = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to load classes: $error')));
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
        const SnackBar(
          content: Text('Select a range that includes a scheduled class day.'),
        ),
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
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 24,
            vertical: 24,
          ),
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Select a class first.')));
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
        const SnackBar(
          content: Text('Pick days that include at least one class meeting.'),
        ),
      );
      return;
    }
    setState(() {
      _isLoadingPreview = true;
      _previewRows = <_ReportRow>[];
    });
    try {
      final List<_StudentRosterEntry> roster = await _fetchRoster(
        selectedClass,
      );

      final AttendanceCalendarService calendar = AttendanceCalendarService(
        firestore: _firestore,
        auth: _auth,
      );
      final Map<DateTime, AttendanceCalendarDay> overrides = await calendar
          .fetchDaysFor(days: _workingDays);

      final Map<DateTime, Map<String, AttendanceMark>> matrix =
          await _fetchAttendanceMatrix(
            classId: selectedClass.id,
            range: range,
            dateKeys: _workingDays,
          );
      final DateTime today = _dayKey(DateTime.now());
      final List<_ReportRow> rows =
          roster.map((_StudentRosterEntry student) {
              final Map<DateTime, AttendanceMark> marks =
                  <DateTime, AttendanceMark>{};
              for (final DateTime day in _workingDays) {
                final DateTime key = _dayKey(day);
                final AttendanceCalendarDay? override = overrides[key];
                if (override != null) {
                  marks[key] = _markForOverride(override.type);
                  continue;
                }
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
            ..sort((a, b) => _compareNamesAsc(a.studentName, b.studentName));
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to build report: $error')));
    }
  }

  Future<void> _exportDocxReport() async {
    final _ClassOption? selectedClass = _resolveSelectedClass();
    final DateTimeRange? range = _selectedRange;
    if (selectedClass == null || range == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select a class and date range first.')),
      );
      return;
    }
    if (_isExportingDocx) return;
    setState(() => _isExportingDocx = true);

    try {
      final List<_StudentRosterEntry> roster = await _fetchRoster(
        selectedClass,
      );

      final AttendanceCalendarService calendar = AttendanceCalendarService(
        firestore: _firestore,
        auth: _auth,
      );
      final Map<DateTime, AttendanceCalendarDay> overrides = await calendar
          .fetchDaysFor(days: _workingDays);

      // Use the same meeting-day list as the preview so dates/marks match.
      final List<DateTime> meetingDays = _workingDays;
      if (meetingDays.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Generate a preview first.')),
        );
        return;
      }

      final Map<DateTime, Map<String, AttendanceMark>> matrix =
          await _fetchAttendanceMatrix(
            classId: selectedClass.id,
            range: range,
            dateKeys: meetingDays,
          );

      final String? instructorId =
          await _fetchMostCommonInstructorIdForSessions(
            classId: selectedClass.id,
            range: range,
          );

      final List<DocxAttendanceRow> docxRows =
          roster.map((_StudentRosterEntry student) {
              final Map<DateTime, AttendanceMark> marks =
                  <DateTime, AttendanceMark>{};
              final DateTime today = _dayKey(DateTime.now());
              for (final DateTime day in meetingDays) {
                final DateTime key = _dayKey(day);
                final AttendanceCalendarDay? override = overrides[key];
                if (override != null) {
                  marks[key] = _markForOverride(override.type);
                  continue;
                }
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
              return DocxAttendanceRow(
                studentName: student.displayName,
                courseYear: courseYear,
                marksByDay: marks,
              );
            }).toList()
            ..sort((a, b) => _compareNamesAsc(a.studentName, b.studentName));

      final Uint8List templateBytes = (await rootBundle.load(
        'assets/reports/template.docx.docx',
      )).buffer.asUint8List();

      final String scheduleLabel = selectedClass.schedules.isEmpty
          ? ''
          : selectedClass.schedules
                .map((e) {
                  final String day = e.dayLabel.trim();
                  final String time = e.timeLabel.trim();
                  if (day.isEmpty && time.isEmpty) {
                    return '';
                  }
                  if (day.isEmpty) {
                    return time;
                  }
                  if (time.isEmpty) {
                    return day;
                  }
                  return '$day $time';
                })
                .where((e) => e.isNotEmpty)
                .join(' • ');

      // Fetch latest template meta (admins can update this at runtime).
      final AttendanceReportTemplateMeta meta =
          await AttendanceReportTemplateMeta.fetch(_firestore);

      final DocxAttendanceHeader header = DocxAttendanceHeader(
        officeOrUnit: selectedClass.departmentName,
        subject: '${selectedClass.subjectCode} • ${selectedClass.subjectName}',
        classSchedule: scheduleLabel,
        courseCode: selectedClass.subjectCode,
        room: selectedClass.schedules.isNotEmpty
            ? selectedClass.schedules
                  .map((e) => e.roomLabel)
                  .where((e) => e.isNotEmpty)
                  .join(' • ')
            : '',
        documentCodeNo: meta.documentCodeNo,
        revisionNo: meta.revisionNo,
        effectiveDate: meta.effectiveDate,
      );

      final String? checkedBy = await _resolveInstructorName(instructorId);
      final String? submittedTo = await _resolveDepartmentHeadName(
        selectedClass.departmentName,
      );

      final Uint8List docxBytes = await buildAttendanceDocxFromContentControls(
        templateDocxBytes: templateBytes,
        header: header,
        sessionDays: meetingDays,
        students: docxRows,
        checkedBy: checkedBy,
        submittedTo: submittedTo,
      );

      final String startKey = _dateKeyString(_dayKey(range.start));
      final String endKey = _dateKeyString(_dayKey(range.end));
      final String fileName =
          'attendance_${selectedClass.sectionLabel}_$startKey-$endKey.docx';

      final String? savedPath = await saveBytesAsFile(docxBytes, fileName);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            savedPath == null
                ? 'Download started: $fileName'
                : 'Saved DOCX to $savedPath',
          ),
        ),
      );
    } catch (error, stackTrace) {
      if (!mounted) return;
      debugPrint('DOCX export failed: $error\n$stackTrace');
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to export DOCX: $error')));
    } finally {
      if (mounted) {
        setState(() => _isExportingDocx = false);
      }
    }
  }

  Future<String?> _fetchMostCommonInstructorIdForSessions({
    required String classId,
    required DateTimeRange range,
  }) async {
    try {
      final DateTime rangeStart = _dayKey(range.start);
      final DateTime rangeEndExclusive = _dayKey(
        range.end,
      ).add(const Duration(days: 1));

      final Map<String, QueryDocumentSnapshot<Map<String, dynamic>>> byId =
          <String, QueryDocumentSnapshot<Map<String, dynamic>>>{};

      Future<void> fetch(String field) async {
        final QuerySnapshot<Map<String, dynamic>> snap = await _firestore
            .collection('attendanceSessions')
            .where('classId', isEqualTo: classId)
            .where(
              field,
              isGreaterThanOrEqualTo: Timestamp.fromDate(rangeStart),
            )
            .where(field, isLessThan: Timestamp.fromDate(rangeEndExclusive))
            .get();
        for (final QueryDocumentSnapshot<Map<String, dynamic>> doc
            in snap.docs) {
          byId.putIfAbsent(doc.id, () => doc);
        }
      }

      await fetch('effectiveStartedAt');
      await fetch('startedAt');

      return _mostCommonNonEmpty(
        byId.values
            .map((doc) => doc.data()['instructorId'] as String?)
            .whereType<String>()
            .toList(),
      );
    } catch (_) {
      return null;
    }
  }

  String? _mostCommonNonEmpty(List<String> values) {
    final Map<String, int> counts = <String, int>{};
    for (final String value in values) {
      final String trimmed = value.trim();
      if (trimmed.isEmpty) continue;
      counts[trimmed] = (counts[trimmed] ?? 0) + 1;
    }
    if (counts.isEmpty) return null;
    String best = counts.keys.first;
    int bestCount = counts[best] ?? 0;
    counts.forEach((key, occurrences) {
      if (occurrences > bestCount) {
        best = key;
        bestCount = occurrences;
      }
    });
    return best;
  }

  String _resolveUserDisplayName(Map<String, dynamic>? data, String fallback) {
    if (data == null) return fallback;
    final List<String?> candidates = <String?>[
      data['displayName'] as String?,
      data['Full Name'] as String?,
      data['fullName'] as String?,
      data['name'] as String?,
    ];
    for (final String? candidate in candidates) {
      final String value = (candidate ?? '').trim();
      if (value.isNotEmpty) return value;
    }
    return fallback;
  }

  Future<String?> _resolveInstructorName(String? instructorId) async {
    final String id = (instructorId ?? '').trim();
    if (id.isEmpty) return null;
    try {
      final DocumentSnapshot<Map<String, dynamic>> doc = await _firestore
          .collection('users')
          .doc(id)
          .get();
      if (!doc.exists) return null;
      return _resolveUserDisplayName(doc.data(), '');
    } catch (_) {
      return null;
    }
  }

  Future<String?> _resolveDepartmentHeadName(String departmentName) async {
    final String name = departmentName.trim();
    if (name.isEmpty) return null;
    try {
      final QuerySnapshot<Map<String, dynamic>> snapshot = await _firestore
          .collection('departments')
          .where('name', isEqualTo: name)
          .limit(1)
          .get();
      if (snapshot.docs.isEmpty) return null;
      final Map<String, dynamic> data = snapshot.docs.first.data();

      final String headName = (data['headName'] as String? ?? '').trim();
      if (headName.isNotEmpty) return headName;

      final String headUserId = (data['headUserId'] as String? ?? '').trim();
      if (headUserId.isEmpty) return null;
      final DocumentSnapshot<Map<String, dynamic>> headDoc = await _firestore
          .collection('users')
          .doc(headUserId)
          .get();
      if (!headDoc.exists) return null;
      return _resolveUserDisplayName(headDoc.data(), '');
    } catch (_) {
      return null;
    }
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

  DateTime _nearestSelectableDay(DateTime date, {required bool forward}) {
    DateTime cursor = DateTime(date.year, date.month, date.day);
    int safety = 0;
    while (!_isSelectableDay(cursor) && safety < 7) {
      cursor = forward
          ? cursor.add(const Duration(days: 1))
          : cursor.subtract(const Duration(days: 1));
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

  Future<List<_StudentRosterEntry>> _fetchRoster(
    _ClassOption selectedClass,
  ) async {
    final QuerySnapshot<Map<String, dynamic>> snapshot = await _firestore
        .collection('users')
        .where('role', isEqualTo: 'student')
        .where('section', isEqualTo: selectedClass.sectionLabel)
        .get();
    final List<_StudentRosterEntry> roster =
        snapshot.docs
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
    final Map<DateTime, Map<String, AttendanceMark>> matrix =
        <DateTime, Map<String, AttendanceMark>>{
          for (final DateTime key in dateKeys)
            _dayKey(key): <String, AttendanceMark>{},
        };
    final DateTime rangeStart = _dayKey(range.start);
    final DateTime rangeEndExclusive = _dayKey(
      range.end,
    ).add(const Duration(days: 1));

    final Map<String, QueryDocumentSnapshot<Map<String, dynamic>>>
    sessionsById = <String, QueryDocumentSnapshot<Map<String, dynamic>>>{};

    Future<void> fetchSessions(String field) async {
      final Query<Map<String, dynamic>> query = _firestore
          .collection('attendanceSessions')
          .where('classId', isEqualTo: classId)
          .where(field, isGreaterThanOrEqualTo: Timestamp.fromDate(rangeStart))
          .where(field, isLessThan: Timestamp.fromDate(rangeEndExclusive));
      final QuerySnapshot<Map<String, dynamic>> snap = await query.get();
      for (final QueryDocumentSnapshot<Map<String, dynamic>> doc in snap.docs) {
        sessionsById.putIfAbsent(doc.id, () => doc);
      }
    }

    // Prefer simulated/effective timestamps when present, but keep legacy
    // sessions (which only have startedAt) visible via the fallback query.
    await fetchSessions('effectiveStartedAt');
    await fetchSessions('startedAt');

    final List<QueryDocumentSnapshot<Map<String, dynamic>>> sessions =
        sessionsById.values.toList(growable: false);
    await Future.wait(
      sessions.map((QueryDocumentSnapshot<Map<String, dynamic>> doc) async {
        final Map<String, dynamic> data = doc.data();
        final Timestamp? startedAt =
            (data['effectiveStartedAt'] as Timestamp?) ??
            (data['startedAt'] as Timestamp?) ??
            (data['createdAt'] as Timestamp?);
        if (startedAt == null) {
          return;
        }
        final DateTime dayKey = _dayKey(startedAt.toDate());
        if (!matrix.containsKey(dayKey)) {
          return;
        }
        final QuerySnapshot<Map<String, dynamic>> attendeesSnapshot = await doc
            .reference
            .collection('attendees')
            .get();
        final Map<String, AttendanceMark> dayMarks = matrix.putIfAbsent(
          dayKey,
          () => <String, AttendanceMark>{},
        );
        for (final QueryDocumentSnapshot<Map<String, dynamic>> attendee
            in attendeesSnapshot.docs) {
          final Map<String, dynamic> attendeeData = attendee.data();
          final AttendanceMark? mark = _statusToMark(
            attendeeData['status'] as String?,
          );
          if (mark != null) {
            dayMarks[attendee.id] = mark;
          }
        }
      }),
    );

    // Apply per-day overrides (e.g., approved excuse requests). Overrides win over
    // session marks and can provide marks even when no session record exists.
    try {
      final DateTime startDay = _dayKey(range.start);
      final DateTime endDay = _dayKey(range.end);
      final String startKey = _dateKeyString(startDay);
      final String endKey = _dateKeyString(endDay);
      final QuerySnapshot<Map<String, dynamic>> overridesSnapshot =
          await _firestore
              .collection('classes')
              .doc(classId)
              .collection('attendanceOverrides')
              .where('dateKey', isGreaterThanOrEqualTo: startKey)
              .where('dateKey', isLessThanOrEqualTo: endKey)
              .get();
      for (final QueryDocumentSnapshot<Map<String, dynamic>> override
          in overridesSnapshot.docs) {
        final Map<String, dynamic> overrideData = override.data();
        final String? dateKeyString = overrideData['dateKey'] as String?;
        final String? studentId = overrideData['studentId'] as String?;
        final String? status = overrideData['status'] as String?;
        if (dateKeyString == null || studentId == null || status == null) {
          continue;
        }
        final AttendanceMark? mark = _statusToMark(status);
        if (mark == null) {
          continue;
        }
        final DateTime? overrideDay = _parseDateKey(dateKeyString);
        if (overrideDay == null) {
          continue;
        }
        final DateTime dayKey = _dayKey(overrideDay);
        if (!matrix.containsKey(dayKey)) {
          continue;
        }
        matrix.putIfAbsent(
          dayKey,
          () => <String, AttendanceMark>{},
        )[studentId] = mark;
      }
    } catch (_) {
      // Best-effort only.
    }
    return matrix;
  }

  String _dateKeyString(DateTime date) {
    final String mm = date.month.toString().padLeft(2, '0');
    final String dd = date.day.toString().padLeft(2, '0');
    return '${date.year}-$mm-$dd';
  }

  DateTime? _parseDateKey(String value) {
    final RegExpMatch? match = RegExp(
      r'^(\d{4})-(\d{2})-(\d{2})$',
    ).firstMatch(value);
    if (match == null) return null;
    final int year = int.parse(match.group(1)!);
    final int month = int.parse(match.group(2)!);
    final int day = int.parse(match.group(3)!);
    return DateTime(year, month, day);
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

  AttendanceMark _markForOverride(AttendanceCalendarDayType type) {
    switch (type) {
      case AttendanceCalendarDayType.holiday:
        return AttendanceMark.holiday;
      case AttendanceCalendarDayType.suspension:
        return AttendanceMark.suspension;
      case AttendanceCalendarDayType.examWeek:
        return AttendanceMark.examWeek;
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
                _workingDays = _expandMeetingDays(
                  _selectedRange!,
                  selectedClass,
                );
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
                      'Select Instructor, Subject, Class/Section, and Date Range to generate the attendance report. You can print or export the generated report(only in .docx format)',
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
    final List<String> sectionOptions = _availableSections();
    final List<_ClassOption> subjectOptions = _classesForSection(
      _selectedSectionLabel,
    );
    final List<_SubjectOption> adminSubjectOptions = _subjectsForAdmin();
    final List<_ClassOption> adminClassOptions = _classesForSubject(
      _selectedSubjectKey,
    );
    final _ClassOption selectedClass =
        _resolveSelectedClass() ??
        (_isAdminFlow
            ? (adminClassOptions.isNotEmpty
                  ? adminClassOptions.first
                  : (_classes.isNotEmpty
                        ? _classes.first
                        : _ClassOption.empty()))
            : (subjectOptions.isNotEmpty
                  ? subjectOptions.first
                  : (_classes.isNotEmpty
                        ? _classes.first
                        : _ClassOption.empty())));
    final String rangeLabel = _selectedRange == null
        ? 'Select date range'
        : '${_formatDate(_selectedRange!.start)} → ${_formatDate(_selectedRange!.end)}';
    final bool canExportDocx =
        _selectedClassId != null && _selectedRange != null && !_isExportingDocx;
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Filters',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 16),
            if (_isAdminFlow) ...<Widget>[
              DropdownButtonFormField<String>(
                initialValue: _selectedInstructorId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Instructor'),
                items: _instructors
                    .map(
                      (_InstructorOption option) => DropdownMenuItem<String>(
                        value: option.uid,
                        child: Text(option.displayName),
                      ),
                    )
                    .toList(),
                onChanged: _isLoadingInstructors
                    ? null
                    : (String? value) async {
                        setState(() {
                          _selectedInstructorId = value;
                          _classes = <_ClassOption>[];
                          _selectedSubjectKey = null;
                          _selectedClassId = null;
                          _selectedSectionLabel = null;
                          _previewRows = <_ReportRow>[];
                          _workingDays = <DateTime>[];
                        });
                        await _loadClassOptions();
                      },
              ),
              if (_isLoadingInstructors)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: LinearProgressIndicator(),
                ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: _selectedSubjectKey,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Subject'),
                items: adminSubjectOptions
                    .map(
                      (_SubjectOption option) => DropdownMenuItem<String>(
                        value: option.key,
                        child: Text(
                          '${option.subjectCode} • ${option.subjectName}',
                        ),
                      ),
                    )
                    .toList(),
                onChanged: _isLoadingClasses
                    ? null
                    : (String? value) {
                        setState(() {
                          _selectedSubjectKey = value;
                          final List<_ClassOption> inSubject =
                              _classesForSubject(_selectedSubjectKey);
                          _selectedClassId = inSubject.isNotEmpty
                              ? inSubject.first.id
                              : null;
                          _previewRows = <_ReportRow>[];
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
              DropdownButtonFormField<String>(
                initialValue: _selectedClassId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Class / Section'),
                items: adminClassOptions
                    .map(
                      (_ClassOption option) => DropdownMenuItem<String>(
                        value: option.id,
                        child: Text(
                          '${option.sectionLabel}${option.termLabel.isEmpty ? '' : ' • ${option.termLabel}'}',
                        ),
                      ),
                    )
                    .toList(),
                onChanged: _isLoadingClasses
                    ? null
                    : (String? value) {
                        setState(() {
                          _selectedClassId = value;
                          _previewRows = <_ReportRow>[];
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
            ] else ...<Widget>[
              DropdownButtonFormField<String>(
                initialValue: _selectedSectionLabel,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Section'),
                items: sectionOptions
                    .map(
                      (String section) => DropdownMenuItem<String>(
                        value: section,
                        child: Text(section),
                      ),
                    )
                    .toList(),
                onChanged: _isLoadingClasses
                    ? null
                    : (String? value) {
                        setState(() {
                          _selectedSectionLabel = value;
                          final List<_ClassOption> inSection =
                              _classesForSection(_selectedSectionLabel);
                          _selectedClassId = inSection.isNotEmpty
                              ? inSection.first.id
                              : null;
                          _previewRows = <_ReportRow>[];
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
              DropdownButtonFormField<String>(
                initialValue: _selectedClassId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Subject'),
                items: subjectOptions
                    .map(
                      (_ClassOption option) => DropdownMenuItem<String>(
                        value: option.id,
                        child: Text(
                          '${option.subjectCode} • ${option.subjectName}',
                        ),
                      ),
                    )
                    .toList(),
                onChanged: _isLoadingClasses
                    ? null
                    : (String? value) {
                        setState(() {
                          _selectedClassId = value;
                          _previewRows = <_ReportRow>[];
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
            ],
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
                  label: Text(
                    _isLoadingPreview
                        ? 'Preparing preview...'
                        : 'Preview roster',
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: canExportDocx ? _exportDocxReport : null,
                  icon: _isExportingDocx
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.description_outlined),
                  label: Text(
                    _isExportingDocx ? 'Preparing DOCX...' : 'Export DOCX',
                  ),
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
        color: colors.surfaceContainerHighest,
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
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
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
      case AttendanceMark.holiday:
        background = colors.surfaceContainerHighest;
      case AttendanceMark.suspension:
        background = colors.surfaceContainerHighest;
      case AttendanceMark.examWeek:
        background = colors.surfaceContainerHighest;
      case null:
        background = colors.surfaceContainerHighest;
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
      _LegendEntry('H', 'Holiday'),
      _LegendEntry('S', 'Suspension'),
      _LegendEntry('Ex', 'Exam Week'),
    ];
    return Wrap(
      spacing: 16,
      runSpacing: 12,
      children: entries
          .map(
            (_LegendEntry entry) =>
                Chip(avatar: Text(entry.symbol), label: Text(entry.label)),
          )
          .toList(),
    );
  }

  List<DateTime> _expandMeetingDays(
    DateTimeRange range,
    _ClassOption? classOption,
  ) {
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

class _InstructorOption {
  const _InstructorOption({required this.uid, required this.displayName});

  final String uid;
  final String displayName;

  static _InstructorOption? fromDoc(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final Map<String, dynamic> data = doc.data();
    final List<String?> candidates = <String?>[
      data['displayName'] as String?,
      data['Full Name'] as String?,
      data['fullName'] as String?,
      data['name'] as String?,
      data['Email'] as String?,
      data['email'] as String?,
    ];
    String best = '';
    for (final String? candidate in candidates) {
      final String value = (candidate ?? '').trim();
      if (value.isNotEmpty) {
        best = value;
        break;
      }
    }
    if (best.isEmpty) {
      best = doc.id;
    }
    return _InstructorOption(uid: doc.id, displayName: best);
  }
}

class _SubjectOption {
  const _SubjectOption({
    required this.key,
    required this.subjectCode,
    required this.subjectName,
  });

  final String key;
  final String subjectCode;
  final String subjectName;
}

class _ClassOption {
  const _ClassOption({
    required this.id,
    required this.subjectId,
    required this.subjectCode,
    required this.subjectName,
    required this.sectionLabel,
    required this.courseYearLabel,
    required this.termLabel,
    required this.meetingWeekdays,
    required this.departmentName,
    required this.schedules,
  });

  final String id;
  final String subjectId;
  final String subjectCode;
  final String subjectName;
  final String sectionLabel;
  final String courseYearLabel;
  final String termLabel;
  final Set<int> meetingWeekdays;
  final String departmentName;
  final List<_ClassScheduleEntry> schedules;

  String get subjectKey {
    final String sid = subjectId.trim();
    if (sid.isNotEmpty) return sid;
    return '${subjectCode.trim()}|${subjectName.trim()}|${departmentName.trim()}';
  }

  static _ClassOption? fromDoc(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final Map<String, dynamic> data = doc.data();
    final String subjectId = (data['subjectId'] as String?) ?? '';
    final String subjectCode = (data['subjectCode'] as String?) ?? 'N/A';
    final String subjectName =
        (data['subjectName'] as String?) ?? 'Untitled Subject';
    final String section = ((data['section'] as String?) ?? 'Section').trim();
    final String courseYear = ((data['courseYear'] as String?) ?? '').trim();
    final String term = (data['term'] as String?) ?? '';
    final String departmentName = ((data['departmentName'] as String?) ?? '')
        .trim();
    final List<dynamic> schedules =
        (data['schedules'] as List<dynamic>? ?? <dynamic>[]);
    final Set<int> meetingWeekdays = _extractMeetingWeekdays(schedules);
    final List<_ClassScheduleEntry> scheduleEntries = schedules
        .map(
          (dynamic entry) =>
              _ClassScheduleEntry.fromMap(entry as Map<String, dynamic>?),
        )
        .whereType<_ClassScheduleEntry>()
        .toList();
    return _ClassOption(
      id: doc.id,
      subjectId: subjectId,
      subjectCode: subjectCode,
      subjectName: subjectName,
      sectionLabel: section.isEmpty ? 'Section' : section,
      courseYearLabel: courseYear.isEmpty ? section : courseYear,
      termLabel: term,
      meetingWeekdays: meetingWeekdays,
      departmentName: departmentName,
      schedules: scheduleEntries,
    );
  }

  factory _ClassOption.empty() => const _ClassOption(
    id: 'placeholder-class',
    subjectId: '',
    subjectCode: 'N/A',
    subjectName: 'No subject',
    sectionLabel: 'Section',
    courseYearLabel: '--',
    termLabel: '',
    meetingWeekdays: _defaultMeetingWeekdays,
    departmentName: '',
    schedules: <_ClassScheduleEntry>[],
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

class _ClassScheduleEntry {
  const _ClassScheduleEntry({
    required this.dayLabel,
    required this.timeLabel,
    required this.roomLabel,
  });

  final String dayLabel;
  final String timeLabel;
  final String roomLabel;

  static _ClassScheduleEntry? fromMap(Map<String, dynamic>? map) {
    if (map == null) return null;
    final String day = (map['day'] as String?)?.trim() ?? '';
    if (day.isEmpty) {
      return null;
    }
    final String timeLabel = _formatScheduleTimeRange(
      map['startTime'] as Map<String, dynamic>?,
      map['endTime'] as Map<String, dynamic>?,
    );
    final String room = ((map['room'] as String?) ?? '').trim();
    return _ClassScheduleEntry(
      dayLabel: day,
      timeLabel: timeLabel,
      roomLabel: room,
    );
  }
}

String _formatScheduleTimeRange(
  Map<String, dynamic>? start,
  Map<String, dynamic>? end,
) {
  final String startLabel = _formatScheduleTime(start);
  final String endLabel = _formatScheduleTime(end);
  if (startLabel.isEmpty && endLabel.isEmpty) {
    return '';
  }
  if (startLabel.isEmpty || endLabel.isEmpty) {
    return startLabel.isNotEmpty ? startLabel : endLabel;
  }
  return '$startLabel - $endLabel';
}

String _formatScheduleTime(Map<String, dynamic>? map) {
  if (map == null) {
    return '';
  }
  final int hour = (map['hour'] as num?)?.toInt() ?? 0;
  final int minute = (map['minute'] as num?)?.toInt() ?? 0;
  final String period = ((map['period'] as String?) ?? '').trim().toUpperCase();
  final String paddedHour = hour.toString().padLeft(2, '0');
  final String paddedMinute = minute.toString().padLeft(2, '0');
  final String suffix = period.isEmpty ? '' : ' $period';
  if (hour == 0 && minute == 0 && period.isEmpty) {
    return '';
  }
  return '$paddedHour:$paddedMinute$suffix';
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
    final String? courseYear = ((data['courseYear'] as String?) ?? section)
        ?.trim();
    return _StudentRosterEntry(
      id: doc.id,
      displayName: name,
      courseYear: (courseYear == null || courseYear.isEmpty)
          ? null
          : courseYear,
    );
  }

  static String _resolveDisplayName(
    Map<String, dynamic> data,
    String fallbackId,
  ) {
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
        return 'E';
      case AttendanceMark.holiday:
        return 'H';
      case AttendanceMark.suspension:
        return 'S';
      case AttendanceMark.examWeek:
        return 'Ex';
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
    return List<int>.generate(
      endYear - startYear + 1,
      (int i) => startYear + i,
    );
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
    final int minMonth = year == widget.firstDate.year
        ? widget.firstDate.month
        : 1;
    final int maxMonth = year == widget.lastDate.year
        ? widget.lastDate.month
        : 12;
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
                            initialValue: _displayMonth,
                            decoration: const InputDecoration(
                              labelText: 'Month',
                            ),
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
                            initialValue: _displayYear,
                            decoration: const InputDecoration(
                              labelText: 'Year',
                            ),
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
                    Text(_selectionLabel, style: theme.textTheme.bodyMedium),
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
    final int leadingEmpty =
        (DateTime(anchor.year, anchor.month, 1).weekday + 6) % 7;
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
    final bool selectable = withinBounds && widget.selectableDayPredicate(day);
    final bool isStart = _rangeStart != null && _isSameDay(day, _rangeStart!);
    final bool isEnd = _rangeEnd != null && _isSameDay(day, _rangeEnd!);
    final bool hasBoth = _rangeStart != null && _rangeEnd != null;
    final bool inBetween =
        hasBoth && !day.isBefore(_rangeStart!) && !day.isAfter(_rangeEnd!);

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
      background = selectable ? colors.surfaceContainerHighest : colors.surface;
      foreground = selectable
          ? theme.textTheme.bodyMedium?.color ?? colors.onSurface
          : theme.disabledColor;
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
    const List<String> labels = <String>[
      'Mon',
      'Tue',
      'Wed',
      'Thu',
      'Fri',
      'Sat',
      'Sun',
    ];
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: labels
          .map(
            (String label) => Expanded(
              child: Center(
                child: Text(
                  label,
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          )
          .toList(),
    );
  }
}
