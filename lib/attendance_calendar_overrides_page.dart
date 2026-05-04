import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'services/attendance_calendar_service.dart';

class AttendanceCalendarOverridesPage extends StatefulWidget {
  const AttendanceCalendarOverridesPage({super.key});

  static const String routeName = '/admin/calendar-overrides';

  @override
  State<AttendanceCalendarOverridesPage> createState() =>
      _AttendanceCalendarOverridesPageState();
}

class _AttendanceCalendarOverridesPageState
    extends State<AttendanceCalendarOverridesPage> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  late final AttendanceCalendarService _calendar = AttendanceCalendarService(
    firestore: _firestore,
    auth: _auth,
  );

  AttendanceCalendarDayType _type = AttendanceCalendarDayType.holiday;
  final TextEditingController _reasonController = TextEditingController();

  late DateTimeRange _range;
  bool _isSaving = false;
  bool _isLoading = false;
  List<AttendanceCalendarDay> _entries = <AttendanceCalendarDay>[];

  @override
  void initState() {
    super.initState();
    final DateTime today = _dayKey(DateTime.now());
    _range = DateTimeRange(start: today, end: today);
    _loadEntries();
  }

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  DateTime _dayKey(DateTime date) => DateTime(date.year, date.month, date.day);

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

  String _formatDate(DateTime date) {
    final DateTime d = _dayKey(date);
    final String mm = d.month.toString().padLeft(2, '0');
    final String dd = d.day.toString().padLeft(2, '0');
    return '${d.year}-$mm-$dd';
  }

  Future<void> _pickRange() async {
    final DateTimeRange? picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      initialDateRange: _range,
    );
    if (picked == null || !mounted) return;
    setState(
      () => _range = DateTimeRange(
        start: _dayKey(picked.start),
        end: _dayKey(picked.end),
      ),
    );
    await _loadEntries();
  }

  Future<void> _loadEntries() async {
    if (_isLoading) return;
    setState(() => _isLoading = true);

    try {
      final String startKey = AttendanceCalendarDay.dateKeyFor(_range.start);
      final String endKey = AttendanceCalendarDay.dateKeyFor(_range.end);

      final QuerySnapshot<Map<String, dynamic>> snap = await _firestore
          .collection('attendanceCalendarDays')
          .where('dateKey', isGreaterThanOrEqualTo: startKey)
          .where('dateKey', isLessThanOrEqualTo: endKey)
          .orderBy('dateKey')
          .get();

      final List<AttendanceCalendarDay> parsed = <AttendanceCalendarDay>[];
      for (final QueryDocumentSnapshot<Map<String, dynamic>> doc in snap.docs) {
        final AttendanceCalendarDay? day = AttendanceCalendarDay.fromDoc(doc);
        if (day != null) parsed.add(day);
      }

      if (!mounted) return;
      setState(() {
        _entries = parsed;
        _isLoading = false;
      });
    } on FirebaseException catch (error) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      final String message = error.code == 'permission-denied'
          ? 'Permission denied loading overrides. Deploy updated Firestore rules and ensure you are signed in.'
          : 'Failed to load overrides: $error';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (error) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to load overrides: $error')),
      );
    }
  }

  String _typeLabel(AttendanceCalendarDayType type) {
    return switch (type) {
      AttendanceCalendarDayType.holiday => 'Holiday (H)',
      AttendanceCalendarDayType.suspension => 'Suspension (S)',
      AttendanceCalendarDayType.examWeek => 'Exam Week (Ex)',
      AttendanceCalendarDayType.schoolActivity => 'School Activity (A)',
    };
  }

  Future<void> _saveDay() async {
    if (_isSaving) return;
    setState(() => _isSaving = true);
    try {
      await _calendar.upsertDay(
        day: _range.start,
        type: _type,
        reason: _reasonController.text,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Saved ${_formatDate(_range.start)}.')),
      );
      await _loadEntries();
    } on FirebaseException catch (error) {
      if (!mounted) return;
      final String message = error.code == 'permission-denied'
          ? 'Permission denied saving. Deploy updated Firestore rules and ensure your account is admin.'
          : 'Failed to save day: $error';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to save day: $error')));
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _saveRange() async {
    if (_isSaving) return;
    setState(() => _isSaving = true);
    try {
      await _calendar.upsertRange(
        start: _range.start,
        end: _range.end,
        type: _type,
        reason: _reasonController.text,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Saved range ${_formatDate(_range.start)} → ${_formatDate(_range.end)}.',
          ),
        ),
      );
      await _loadEntries();
    } on FirebaseException catch (error) {
      if (!mounted) return;
      final String message = error.code == 'permission-denied'
          ? 'Permission denied saving. Deploy updated Firestore rules and ensure your account is admin.'
          : 'Failed to save range: $error';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to save range: $error')));
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _deleteDay(DateTime day) async {
    if (_isSaving) return;
    setState(() => _isSaving = true);
    try {
      await _calendar.deleteDay(day: day);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Deleted ${_formatDate(day)}.')));
      await _loadEntries();
    } on FirebaseException catch (error) {
      if (!mounted) return;
      final String message = error.code == 'permission-denied'
          ? 'Permission denied deleting. Deploy updated Firestore rules and ensure your account is admin.'
          : 'Failed to delete: $error';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to delete: $error')));
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Widget _buildEntryTile(AttendanceCalendarDay entry) {
    final DateTime? parsedDay = _parseDateKey(entry.dateKey);
    final String title = parsedDay == null
        ? entry.dateKey
        : _formatDate(parsedDay);
    final String subtitle = <String>[
      '${entry.label} (${entry.code})',
      if ((entry.reason ?? '').trim().isNotEmpty) entry.reason!.trim(),
    ].join(' — ');

    return ListTile(
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: IconButton(
        tooltip: 'Delete',
        onPressed: _isSaving
            ? null
            : () async {
                final ScaffoldMessengerState messenger = ScaffoldMessenger.of(
                  context,
                );
                final bool? ok = await showDialog<bool>(
                  context: context,
                  builder: (BuildContext context) => AlertDialog(
                    title: const Text('Delete override?'),
                    content: Text('Remove override for $title?'),
                    actions: <Widget>[
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(false),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.of(context).pop(true),
                        child: const Text('Delete'),
                      ),
                    ],
                  ),
                );
                if (!mounted) return;
                if (ok != true) return;
                if (parsedDay == null) {
                  messenger.showSnackBar(
                    const SnackBar(content: Text('Invalid date key.')),
                  );
                  return;
                }
                await _deleteDay(parsedDay);
              },
        icon: const Icon(Icons.delete_outline),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Calendar Overrides'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Refresh',
            onPressed: _isLoading ? null : _loadEntries,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
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
                      'Set a day or range where attendance is disabled.',
                      style: theme.textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _pickRange,
                            icon: const Icon(Icons.date_range_outlined),
                            label: Text(
                              '${_formatDate(_range.start)} → ${_formatDate(_range.end)}',
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<AttendanceCalendarDayType>(
                      initialValue: _type,
                      items: AttendanceCalendarDayType.values
                          .map(
                            (AttendanceCalendarDayType t) =>
                                DropdownMenuItem<AttendanceCalendarDayType>(
                                  value: t,
                                  child: Text(_typeLabel(t)),
                                ),
                          )
                          .toList(),
                      onChanged: _isSaving
                          ? null
                          : (AttendanceCalendarDayType? next) {
                              if (next == null) return;
                              setState(() => _type = next);
                            },
                      decoration: const InputDecoration(labelText: 'Type'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _reasonController,
                      enabled: !_isSaving,
                      decoration: const InputDecoration(
                        labelText: 'Reason (optional)',
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: FilledButton(
                            onPressed: _isSaving ? null : _saveDay,
                            child: const Text('Save Day'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton.tonal(
                            onPressed: _isSaving ? null : _saveRange,
                            child: const Text('Save Range'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: <Widget>[
                Text('Overrides in range', style: theme.textTheme.titleMedium),
                const Spacer(),
                if (_isLoading)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (_entries.isEmpty && !_isLoading)
              const Text('No overrides set for this range.'),
            if (_entries.isNotEmpty)
              Card(
                child: Column(
                  children: _entries
                      .map(_buildEntryTile)
                      .toList(growable: false),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
