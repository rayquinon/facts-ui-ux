import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import 'analytics_class_picker_page.dart';

class AnalyticsDashboardPage extends StatefulWidget {
  const AnalyticsDashboardPage({
    super.key,
    required this.classInfo,
    required this.studentId,
    required this.studentName,
  });

  final AnalyticsClassInfo classInfo;
  final String studentId;
  final String? studentName;

  @override
  State<AnalyticsDashboardPage> createState() => _AnalyticsDashboardPageState();
}

class _AnalyticsDashboardPageState extends State<AnalyticsDashboardPage> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final RegExp _dateKeyPattern = RegExp(r'^\d{4}-\d{2}-\d{2}$');

  late DateTimeRange _range;
  bool _loading = false;
  Object? _error;
  List<_DailyAnalyticsRow> _rows = const <_DailyAnalyticsRow>[];

  @override
  void initState() {
    super.initState();
    final DateTime now = DateTime.now();
    final DateTime end = DateTime(now.year, now.month, now.day);
    final DateTime start = end.subtract(const Duration(days: 29));
    _range = DateTimeRange(start: start, end: end);
    _load();
  }

  String _dateKey(DateTime date) {
    final DateTime d = DateTime(date.year, date.month, date.day);
    final String mm = d.month.toString().padLeft(2, '0');
    final String dd = d.day.toString().padLeft(2, '0');
    return '${d.year}-$mm-$dd';
  }

  String _formatRange(DateTimeRange range) {
    return '${_dateKey(range.start)} – ${_dateKey(range.end)}';
  }

  Future<void> _setPresetDays(int days) async {
    final DateTime now = DateTime.now();
    final DateTime end = DateTime(now.year, now.month, now.day);
    final DateTime start = end.subtract(Duration(days: days - 1));
    setState(() {
      _range = DateTimeRange(start: start, end: end);
    });
    await _load();
  }

  Future<void> _pickRange() async {
    final DateTimeRange? picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      initialDateRange: _range,
    );
    if (picked == null || !mounted) return;
    setState(() {
      _range = DateTimeRange(
        start: DateTime(
          picked.start.year,
          picked.start.month,
          picked.start.day,
        ),
        end: DateTime(picked.end.year, picked.end.month, picked.end.day),
      );
    });
    await _load();
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final String startKey = _dateKey(_range.start);
      final String endKey = _dateKey(_range.end);

      final QuerySnapshot<Map<String, dynamic>> snap = await _firestore
          .collection('classes')
          .doc(widget.classInfo.id)
          .collection('students')
          .doc(widget.studentId)
          .collection('daily')
          .where('dateKey', isGreaterThanOrEqualTo: startKey)
          .where('dateKey', isLessThanOrEqualTo: endKey)
          .orderBy('dateKey')
          .get();

      List<_DailyAnalyticsRow> rows = snap.docs
          .map(_DailyAnalyticsRow.fromDoc)
          .whereType<_DailyAnalyticsRow>()
          .toList(growable: false);

      if (rows.isEmpty) {
        rows = await _loadRowsFromSessionAttendees(
          startKey: startKey,
          endKey: endKey,
        );
      }

      if (!mounted) return;
      setState(() {
        _rows = rows;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _rows = const <_DailyAnalyticsRow>[];
        _loading = false;
        _error = e;
      });
    }
  }

  Future<List<_DailyAnalyticsRow>> _loadRowsFromSessionAttendees({
    required String startKey,
    required String endKey,
  }) async {
    final QuerySnapshot<Map<String, dynamic>> sessionSnap = await _firestore
        .collection('attendanceSessions')
        .where('classId', isEqualTo: widget.classInfo.id)
        .get();

    final Map<String, _DailyAggregate> byDate = <String, _DailyAggregate>{};

    for (final QueryDocumentSnapshot<Map<String, dynamic>> sessionDoc
        in sessionSnap.docs) {
      final Map<String, dynamic> session = sessionDoc.data();
      final String? dateKey = _sessionDateKey(session);
      if (dateKey == null) {
        continue;
      }
      if (dateKey.compareTo(startKey) < 0 || dateKey.compareTo(endKey) > 0) {
        continue;
      }

      final DocumentSnapshot<Map<String, dynamic>> attendeeSnap =
          await sessionDoc.reference
              .collection('attendees')
              .doc(widget.studentId)
              .get();
      if (!attendeeSnap.exists) {
        continue;
      }

      final Map<String, dynamic>? attendee = attendeeSnap.data();
      if (attendee == null) {
        continue;
      }

      final String status = ((attendee['status'] as String?) ?? '')
          .trim()
          .toLowerCase();
      final int minutesLate = _asInt(attendee['minutesLate']);
      final int minutesAbsent = _asInt(attendee['minutesAbsent']);

      final _DailyAggregate agg = byDate.putIfAbsent(
        dateKey,
        () => _DailyAggregate(dateKey: dateKey),
      );

      switch (status) {
        case 'present':
        case 'excused':
          agg.presentCount += 1;
          break;
        case 'late':
          agg.lateCount += 1;
          agg.lateMinutes += minutesLate;
          break;
        case 'absent':
          agg.absentCount += 1;
          agg.absentMinutes += minutesAbsent;
          break;
      }
    }

    final List<_DailyAnalyticsRow> rows =
        byDate.values
            .map((_DailyAggregate aggregate) => aggregate.toRow())
            .toList(growable: false)
          ..sort((a, b) => a.dateKey.compareTo(b.dateKey));
    return rows;
  }

  String? _sessionDateKey(Map<String, dynamic> session) {
    final String? effective = (session['effectiveDateKey'] as String?)?.trim();
    if (_isDateKey(effective)) {
      return effective;
    }

    final String? dateKey = (session['dateKey'] as String?)?.trim();
    if (_isDateKey(dateKey)) {
      return dateKey;
    }

    final Object? startedAt = session['startedAt'];
    if (startedAt is Timestamp) {
      return _dateKey(startedAt.toDate());
    }

    return null;
  }

  bool _isDateKey(String? value) {
    if (value == null || value.isEmpty) {
      return false;
    }
    return _dateKeyPattern.hasMatch(value);
  }

  int _asInt(Object? value) {
    if (value is num) {
      return value.round();
    }
    if (value is String) {
      return int.tryParse(value.trim()) ?? 0;
    }
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    final String classLabel = widget.classInfo.subjectName.isNotEmpty
        ? '${widget.classInfo.subjectCode} • ${widget.classInfo.subjectName}'
        : (widget.classInfo.subjectCode.isNotEmpty
              ? widget.classInfo.subjectCode
              : 'Class');

    final int presentCount = _rows.fold<int>(
      0,
      (int sum, _DailyAnalyticsRow r) => sum + r.presentCount,
    );
    final int lateCount = _rows.fold<int>(
      0,
      (int sum, _DailyAnalyticsRow r) => sum + r.lateCount,
    );
    final int absentCount = _rows.fold<int>(
      0,
      (int sum, _DailyAnalyticsRow r) => sum + r.absentCount,
    );
    final int lateMinutes = _rows.fold<int>(
      0,
      (int sum, _DailyAnalyticsRow r) => sum + r.lateMinutes,
    );
    final int absentMinutes = _rows.fold<int>(
      0,
      (int sum, _DailyAnalyticsRow r) => sum + r.absentMinutes,
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Analytics')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      classLabel,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 6),
                    if ((widget.studentName ?? '').trim().isNotEmpty)
                      Text(
                        widget.studentName!,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    if (widget.classInfo.section.isNotEmpty ||
                        widget.classInfo.term.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          <String>[
                            if (widget.classInfo.section.isNotEmpty)
                              'Section ${widget.classInfo.section}',
                            if (widget.classInfo.term.isNotEmpty)
                              widget.classInfo.term,
                          ].join(' • '),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.outline,
                          ),
                        ),
                      ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: <Widget>[
                        OutlinedButton.icon(
                          onPressed: _pickRange,
                          icon: const Icon(Icons.date_range_outlined),
                          label: Text(_formatRange(_range)),
                        ),
                        OutlinedButton(
                          onPressed: () => _setPresetDays(7),
                          child: const Text('7d'),
                        ),
                        OutlinedButton(
                          onPressed: () => _setPresetDays(30),
                          child: const Text('30d'),
                        ),
                        OutlinedButton(
                          onPressed: () => _setPresetDays(90),
                          child: const Text('90d'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (_error != null)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'Failed to load analytics: $_error',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              )
            else
              _SummaryGrid(
                presentCount: presentCount,
                lateCount: lateCount,
                absentCount: absentCount,
                lateMinutes: lateMinutes,
                absentMinutes: absentMinutes,
              ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Daily breakdown',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 10),
                    if (_loading)
                      const Center(child: CircularProgressIndicator())
                    else if (_rows.isEmpty)
                      Text(
                        'No analytics data for this range.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      )
                    else
                      Column(
                        children: _rows
                            .map(
                              (_DailyAnalyticsRow r) => Padding(
                                padding: const EdgeInsets.only(bottom: 10),
                                child: _DailyRowTile(row: r),
                              ),
                            )
                            .toList(growable: false),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DailyAnalyticsRow {
  _DailyAnalyticsRow({
    required this.dateKey,
    required this.presentCount,
    required this.lateCount,
    required this.absentCount,
    required this.lateMinutes,
    required this.absentMinutes,
  });

  final String dateKey;
  final int presentCount;
  final int lateCount;
  final int absentCount;
  final int lateMinutes;
  final int absentMinutes;

  static _DailyAnalyticsRow? fromDoc(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final Map<String, dynamic> data = doc.data();
    final String dateKey = (data['dateKey'] as String?)?.trim() ?? doc.id;
    if (dateKey.isEmpty) return null;

    int asInt(Object? v) {
      if (v is num) return v.round();
      return 0;
    }

    return _DailyAnalyticsRow(
      dateKey: dateKey,
      presentCount: asInt(data['presentCount']),
      lateCount: asInt(data['lateCount']),
      absentCount: asInt(data['absentCount']),
      lateMinutes: asInt(data['lateMinutes']),
      absentMinutes: asInt(data['absentMinutes']),
    );
  }
}

class _DailyAggregate {
  _DailyAggregate({required this.dateKey});

  final String dateKey;
  int presentCount = 0;
  int lateCount = 0;
  int absentCount = 0;
  int lateMinutes = 0;
  int absentMinutes = 0;

  _DailyAnalyticsRow toRow() {
    return _DailyAnalyticsRow(
      dateKey: dateKey,
      presentCount: presentCount,
      lateCount: lateCount,
      absentCount: absentCount,
      lateMinutes: lateMinutes,
      absentMinutes: absentMinutes,
    );
  }
}

class _SummaryGrid extends StatelessWidget {
  const _SummaryGrid({
    required this.presentCount,
    required this.lateCount,
    required this.absentCount,
    required this.lateMinutes,
    required this.absentMinutes,
  });

  final int presentCount;
  final int lateCount;
  final int absentCount;
  final int lateMinutes;
  final int absentMinutes;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool wide = constraints.maxWidth >= 560;
        final int columns = wide ? 3 : 2;

        final List<Widget> tiles = <Widget>[
          _SummaryTile(label: 'Present', value: presentCount.toString()),
          _SummaryTile(label: 'Late', value: lateCount.toString()),
          _SummaryTile(label: 'Absent', value: absentCount.toString()),
          _SummaryTile(label: 'Late minutes', value: lateMinutes.toString()),
          _SummaryTile(
            label: 'Absent minutes',
            value: absentMinutes.toString(),
          ),
        ];

        return GridView.count(
          crossAxisCount: columns,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 2.0,
          physics: const NeverScrollableScrollPhysics(),
          shrinkWrap: true,
          children: tiles,
        );
      },
    );
  }
}

class _SummaryTile extends StatelessWidget {
  const _SummaryTile({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              value,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DailyRowTile extends StatelessWidget {
  const _DailyRowTile({required this.row});

  final _DailyAnalyticsRow row;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String subtitle = <String>[
      'P ${row.presentCount}',
      'L ${row.lateCount}',
      'A ${row.absentCount}',
      'LateMin ${row.lateMinutes}',
      'AbsMin ${row.absentMinutes}',
    ].join(' • ');

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outline),
        borderRadius: BorderRadius.circular(18),
      ),
      child: ListTile(
        dense: true,
        title: Text(row.dateKey),
        subtitle: Text(subtitle),
      ),
    );
  }
}
