import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'attendance_session_page.dart';

class InstructorPage extends StatefulWidget {
  const InstructorPage({super.key});

  static const String routeName = '/instructor';

  @override
  State<InstructorPage> createState() => _InstructorPageState();
}

class _InstructorPageState extends State<InstructorPage> {

  bool _simulationEnabled = true;
  late DateTime _simulatedTime;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _assignmentSubscription;
  bool _isLoadingAssignments = true;
  String? _assignmentError;
  List<_InstructorClassAssignment> _assignments = <_InstructorClassAssignment>[];
  List<_InstructorSchedule> _scheduleEntries = <_InstructorSchedule>[];
  bool _isLaunchingSession = false;

  DateTime get _activeTime => _simulationEnabled ? _simulatedTime : DateTime.now();

  @override
  void initState() {
    super.initState();
    _simulatedTime = DateTime.now();
    _subscribeToAssignments();
  }

  @override
  void dispose() {
    _assignmentSubscription?.cancel();
    super.dispose();
  }

  Future<void> _handleSignOut() async {
    try {
      await FirebaseAuth.instance.signOut();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to sign out. Please try again.')),
      );
      return;
    }

    if (!mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil('/login', (Route<dynamic> route) => false);
  }

  void _adjustSimulatedTime(Duration delta) {
    if (!_simulationEnabled) return;
    setState(() => _simulatedTime = _simulatedTime.add(delta));
  }

  void _resetSimulatedTime() {
    if (!_simulationEnabled) return;
    setState(() => _simulatedTime = DateTime.now());
  }

  void _toggleSimulation(bool enabled) {
    if (enabled == _simulationEnabled) return;
    setState(() {
      _simulationEnabled = enabled;
      _simulatedTime = DateTime.now();
    });
  }

  Future<void> _pickSimulatedDate() async {
    if (!_simulationEnabled) return;
    final DateTime now = DateTime.now();
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _simulatedTime,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 1),
    );
    if (picked == null) return;
    setState(() {
      _simulatedTime = DateTime(
        picked.year,
        picked.month,
        picked.day,
        _simulatedTime.hour,
        _simulatedTime.minute,
      );
    });
  }

  Future<void> _pickSimulatedTime() async {
    if (!_simulationEnabled) return;
    final TimeOfDay? picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_simulatedTime),
    );
    if (picked == null) return;
    setState(() {
      _simulatedTime = DateTime(
        _simulatedTime.year,
        _simulatedTime.month,
        _simulatedTime.day,
        picked.hour,
        picked.minute,
      );
    });
  }

  void _subscribeToAssignments() {
    final User? user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      setState(() {
        _assignmentError = 'You must be signed in to view your assigned classes.';
        _isLoadingAssignments = false;
        _assignments = <_InstructorClassAssignment>[];
        _scheduleEntries = <_InstructorSchedule>[];
      });
      return;
    }

    _assignmentSubscription?.cancel();
    setState(() {
      _isLoadingAssignments = true;
      _assignmentError = null;
    });

    _assignmentSubscription = FirebaseFirestore.instance
        .collection('classes')
        .where('instructorId', isEqualTo: user.uid)
        .snapshots()
        .listen(
      (QuerySnapshot<Map<String, dynamic>> snapshot) {
        final List<_InstructorClassAssignment> assignments = snapshot.docs
            .map(_InstructorClassAssignment.fromDocument)
            .whereType<_InstructorClassAssignment>()
            .toList();
        final List<_InstructorSchedule> scheduleEntries = assignments
            .expand((_InstructorClassAssignment assignment) => assignment.schedules)
            .toList()
          ..sort(_InstructorSchedule.compareByDayAndTime);
        setState(() {
          _assignments = assignments;
          _scheduleEntries = scheduleEntries;
          _isLoadingAssignments = false;
          _assignmentError = null;
        });
      },
      onError: (Object error, StackTrace stackTrace) {
        setState(() {
          _assignmentError = 'Failed to load classes. $error';
          _isLoadingAssignments = false;
          _assignments = <_InstructorClassAssignment>[];
          _scheduleEntries = <_InstructorSchedule>[];
        });
      },
    );
  }

  _InstructorSchedule? _resolveActiveSchedule(DateTime time) {
    for (final _InstructorSchedule schedule in _scheduleEntries) {
      if (schedule.isActive(time)) return schedule;
    }
    return null;
  }

  _InstructorSchedule? _resolveNextSchedule(DateTime time) {
    _InstructorSchedule? nearest;
    Duration? nearestDifference;
    for (final _InstructorSchedule schedule in _scheduleEntries) {
      final Duration diff = schedule.timeUntilStart(time);
      if (diff.isNegative) continue;
      if (nearest == null || diff < nearestDifference!) {
        nearest = schedule;
        nearestDifference = diff;
      }
    }
    return nearest;
  }

  Future<void> _startRecognitionSession(_InstructorSchedule schedule) async {
    if (_isLaunchingSession) return;
    setState(() => _isLaunchingSession = true);
    final AttendanceSessionConfig config = AttendanceSessionConfig(
      classId: schedule.classId,
      subjectCode: schedule.subjectCode,
      subjectName: schedule.subjectName,
      section: schedule.section,
      term: schedule.term,
      location: schedule.location,
      dayOfWeek: schedule.dayOfWeek,
      start: schedule.start,
      end: schedule.end,
    );
    try {
      final bool? completed = await Navigator.of(context).push<bool?>(
        MaterialPageRoute<bool?>(
          builder: (BuildContext context) => AttendanceSessionPage(config: config),
          settings: RouteSettings(
            name: AttendanceSessionPage.routeName,
            arguments: config,
          ),
        ),
      );
      if (!mounted) return;
      if (completed == true) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Recognition session ended and saved.')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLaunchingSession = false);
      } else {
        _isLaunchingSession = false;
      }
    }
  }

  List<_InstructorStat> _buildInstructorStats(DateTime activeTime) {
    final int sessionsToday =
        _scheduleEntries.where((_InstructorSchedule entry) => entry.dayOfWeek == activeTime.weekday).length;
    final int assignedSections = _assignments.length;
    final int weeklySessions = _scheduleEntries.length;

    return <_InstructorStat>[
      _InstructorStat(label: 'Classes Today', value: _formatCounter(sessionsToday), icon: Icons.event_note_outlined),
      _InstructorStat(label: 'Assigned Sections', value: _formatCounter(assignedSections), icon: Icons.layers_outlined),
      _InstructorStat(label: 'Weekly Sessions', value: _formatCounter(weeklySessions), icon: Icons.schedule_outlined),
    ];
  }

  String _formatCounter(int value) => value.toString().padLeft(2, '0');

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final DateTime activeTime = _activeTime;
    final _InstructorSchedule? activeSchedule = _resolveActiveSchedule(activeTime);
    final _InstructorSchedule? nextSchedule = _resolveNextSchedule(activeTime);
    final List<_InstructorStat> stats = _buildInstructorStats(activeTime);
    final bool showLoadingState = _isLoadingAssignments && _assignments.isEmpty;
    final bool hasAssignments = _assignments.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Instructor Workspace'),
        actions: <Widget>[
          TextButton.icon(
            onPressed: _handleSignOut,
            icon: const Icon(Icons.logout, size: 18),
            label: const Text('Sign out'),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _buildSimulationPanel(context, activeTime),
              const SizedBox(height: 24),
              _buildStatsSection(theme, stats, showLoadingState),
              const SizedBox(height: 32),
              _buildNextUpCard(
                context,
                nextSchedule,
                activeTime,
                showLoadingState,
                _assignmentError,
                hasAssignments,
              ),
              const SizedBox(height: 24),
              _buildSessionControlCard(
                context,
                activeSchedule,
                showLoadingState,
                _assignmentError,
                hasAssignments,
              ),
              const SizedBox(height: 32),
              _buildScheduleSection(
                context,
                activeTime,
                nextSchedule,
                showLoadingState,
                _assignmentError,
                hasAssignments,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSimulationPanel(BuildContext context, DateTime activeTime) {
    final ThemeData theme = Theme.of(context);
    final MaterialLocalizations localizations = MaterialLocalizations.of(context);
    final String timeLabel = localizations.formatTimeOfDay(TimeOfDay.fromDateTime(activeTime));
    final String dateLabel = localizations.formatFullDate(activeTime);

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        _simulationEnabled ? 'Simulated time' : 'Live time',
                        style: theme.textTheme.labelLarge,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        timeLabel,
                        style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      Text(dateLabel, style: theme.textTheme.bodyMedium),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: <Widget>[
                    Text('Simulation mode', style: theme.textTheme.labelLarge),
                    Switch.adaptive(value: _simulationEnabled, onChanged: _toggleSimulation),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: <Widget>[
                OutlinedButton.icon(
                  onPressed:
                      _simulationEnabled ? () => _adjustSimulatedTime(const Duration(minutes: -15)) : null,
                  icon: const Icon(Icons.history_toggle_off),
                  label: const Text('- 15 min'),
                ),
                OutlinedButton.icon(
                  onPressed:
                      _simulationEnabled ? () => _adjustSimulatedTime(const Duration(minutes: 15)) : null,
                  icon: const Icon(Icons.update),
                  label: const Text('+ 15 min'),
                ),
                OutlinedButton.icon(
                  onPressed: _simulationEnabled ? _resetSimulatedTime : null,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Sync to now'),
                ),
                OutlinedButton.icon(
                  onPressed: _simulationEnabled ? _pickSimulatedDate : null,
                  icon: const Icon(Icons.calendar_month_outlined),
                  label: const Text('Pick date'),
                ),
                OutlinedButton.icon(
                  onPressed: _simulationEnabled ? _pickSimulatedTime : null,
                  icon: const Icon(Icons.schedule_outlined),
                  label: const Text('Pick time'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatsSection(
    ThemeData theme,
    List<_InstructorStat> stats,
    bool showLoadingIndicator,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: <Widget>[
            Text(
              'Quick overview',
              style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            if (showLoadingIndicator)
              const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2)),
          ],
        ),
        const SizedBox(height: 16),
        if (stats.isEmpty)
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
            child: const Padding(
              padding: EdgeInsets.all(20),
              child: Text('No classes assigned yet. Coordinate with the admin team to get started.'),
            ),
          )
        else
          Wrap(
            spacing: 16,
            runSpacing: 16,
            children:
                stats.map((_InstructorStat stat) => _InstructorStatCard(stat: stat)).toList(),
          ),
      ],
    );
  }

  Widget _buildNextUpCard(
    BuildContext context,
    _InstructorSchedule? nextSchedule,
    DateTime activeTime,
    bool showLoadingState,
    String? errorMessage,
    bool hasAssignments,
  ) {
    if (showLoadingState && !hasAssignments) {
      return _buildStatusCard(
        context,
        title: 'Loading schedule',
        message: 'Fetching assigned sections from admin...',
        child: const CircularProgressIndicator(),
      );
    }

    if (errorMessage != null && !hasAssignments) {
      return _buildStatusCard(
        context,
        title: 'Unable to load schedule',
        message: errorMessage,
      );
    }

    if (!hasAssignments || nextSchedule == null) {
      final String emptyMessage = hasAssignments
          ? 'No upcoming sessions detected based on the current clock.'
          : 'No classes have been assigned to you yet. Ask an admin to link your sections.';
      return _buildStatusCard(
        context,
        title: 'No sessions in queue',
        message: emptyMessage,
      );
    }

    final Duration countdown = nextSchedule.timeUntilStart(activeTime);
    final String countdownLabel = countdown.isNegative
        ? 'Session in progress'
        : 'Starts in ${_formatDuration(countdown)}';

    final ThemeData theme = Theme.of(context);
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ListTile(
        contentPadding: const EdgeInsets.all(20),
        leading: CircleAvatar(
          radius: 28,
          backgroundColor: theme.colorScheme.primaryContainer,
          child: Icon(Icons.class_outlined, color: theme.colorScheme.primary),
        ),
        title: Text(
          '${nextSchedule.subjectCode} • ${nextSchedule.subjectName}',
          style: theme.textTheme.titleMedium,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const SizedBox(height: 4),
            Text(_formatSectionLabel(nextSchedule)),
            const SizedBox(height: 4),
            Text('${_formatScheduleRange(context, nextSchedule)} • ${nextSchedule.location ?? 'Location TBD'}'),
            const SizedBox(height: 6),
            Text(
              countdownLabel,
              style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.primary),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSessionControlCard(
    BuildContext context,
    _InstructorSchedule? activeSchedule,
    bool showLoadingState,
    String? errorMessage,
    bool hasAssignments,
  ) {
    final ThemeData theme = Theme.of(context);
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
                Text(
              'Attendance session',
              style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            if (showLoadingState && !hasAssignments)
              const Center(child: CircularProgressIndicator())
            else if (errorMessage != null && !hasAssignments)
              Text(errorMessage, style: theme.textTheme.bodyMedium)
            else if (!hasAssignments)
              Text(
                'No classes assigned yet. Ask an admin to link your sections before running attendance.',
                style: theme.textTheme.bodyMedium,
              )
            else if (activeSchedule != null) ...<Widget>[
              Text(
                '${activeSchedule.subjectCode} • ${activeSchedule.subjectName}',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(_formatSectionLabel(activeSchedule)),
                  const SizedBox(height: 2),
                  Text(
                    '${_formatScheduleRange(context, activeSchedule)} • ${activeSchedule.location ?? 'Location TBD'}',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed:
                    _isLaunchingSession ? null : () => _startRecognitionSession(activeSchedule),
                icon: _isLaunchingSession
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.play_arrow_rounded),
                label: Text(_isLaunchingSession ? 'Launching...' : 'Start recognition session'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () {},
                icon: const Icon(Icons.edit_note_outlined),
                label: const Text('Log attendance manually'),
              ),
            ] else ...<Widget>[
              Text(
                'No class is running right now. Use the simulated clock to test sessions or wait for your next slot.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: _simulationEnabled
                    ? () => _adjustSimulatedTime(const Duration(minutes: 30))
                    : null,
                icon: const Icon(Icons.schedule_send_outlined),
                label: const Text('Jump +30 min'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildScheduleSection(
    BuildContext context,
    DateTime activeTime,
    _InstructorSchedule? nextSchedule,
    bool showLoadingState,
    String? errorMessage,
    bool hasAssignments,
  ) {
    final ThemeData theme = Theme.of(context);
    final bool hasSchedules = _scheduleEntries.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'Weekly schedule',
          style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 12),
        if (showLoadingState && !hasAssignments)
          _buildStatusCard(
            context,
            title: 'Building timetable',
            message: 'Please wait while we fetch your sections.',
            child: const CircularProgressIndicator(),
          )
        else if (errorMessage != null && !hasAssignments)
          _buildStatusCard(
            context,
            title: 'Unable to show schedule',
            message: errorMessage,
          )
        else if (!hasSchedules)
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            child: const Padding(
              padding: EdgeInsets.all(20),
              child: Text('No sessions configured yet for your account.'),
            ),
          )
        else
          Column(
            children: _scheduleEntries.map((_InstructorSchedule schedule) {
              final bool isActive = schedule.isActive(activeTime);
              final bool isNext = !isActive && nextSchedule == schedule;
              final bool isToday = schedule.dayOfWeek == activeTime.weekday;

              final Color? cardColor = isActive
                  ? theme.colorScheme.primaryContainer
                  : isNext
                      ? theme.colorScheme.surfaceContainerHighest
                      : null;

              return Card(
                color: cardColor,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                margin: const EdgeInsets.symmetric(vertical: 8),
                child: ListTile(
                  leading: Icon(
                    isActive ? Icons.play_circle_fill : Icons.class_outlined,
                    color: isActive
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                  title: Text('${schedule.subjectCode} • ${schedule.subjectName}'),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(_formatSectionLabel(schedule)),
                      const SizedBox(height: 2),
                      Text('${_formatScheduleRange(context, schedule)} • ${schedule.location ?? 'Location TBD'}'),
                    ],
                  ),
                  trailing: Wrap(
                    spacing: 6,
                    children: <Widget>[
                      if (isActive)
                        Chip(
                          label: const Text('Now'),
                          backgroundColor: theme.colorScheme.primary,
                          labelStyle: TextStyle(
                            color: theme.colorScheme.onPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        )
                      else if (isNext)
                        Chip(
                          label: const Text('Next'),
                          backgroundColor: theme.colorScheme.secondaryContainer,
                        )
                      else if (isToday)
                        Chip(
                          label: const Text('Today'),
                          backgroundColor: theme.colorScheme.surfaceContainerHigh,
                        ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
      ],
    );
  }

  Widget _buildStatusCard(
    BuildContext context, {
    required String title,
    required String message,
    Widget? child,
  }) {
    final ThemeData theme = Theme.of(context);
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(message, style: theme.textTheme.bodyMedium),
            if (child != null) ...<Widget>[
              const SizedBox(height: 12),
              child,
            ],
          ],
        ),
      ),
    );
  }

  String _formatSectionLabel(_InstructorSchedule schedule) {
    final String sectionLabel = schedule.section == null ? 'Section TBD' : 'Section ${schedule.section}';
    final String termLabel = schedule.term == null ? '' : ' • ${schedule.term}';
    return '$sectionLabel$termLabel';
  }

  String _formatScheduleRange(BuildContext context, _InstructorSchedule schedule) {
    final String startLabel = schedule.start.format(context);
    final String endLabel = schedule.end.format(context);
    final String dayLabel = _weekdayLabel(schedule.dayOfWeek);
    return '$dayLabel • $startLabel - $endLabel';
  }

  String _formatDuration(Duration duration) {
    final int hours = duration.inHours;
    final int minutes = duration.inMinutes.remainder(60);
    if (hours > 0) {
      return '${hours}h ${minutes}m';
    }
    return '${minutes}m';
  }

  String _weekdayLabel(int day) {
    switch (day) {
      case DateTime.monday:
        return 'Monday';
      case DateTime.tuesday:
        return 'Tuesday';
      case DateTime.wednesday:
        return 'Wednesday';
      case DateTime.thursday:
        return 'Thursday';
      case DateTime.friday:
        return 'Friday';
      case DateTime.saturday:
        return 'Saturday';
      default:
        return 'Sunday';
    }
  }
}

class _InstructorStatCard extends StatelessWidget {
  const _InstructorStatCard({required this.stat});

  final _InstructorStat stat;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return SizedBox(
      width: 200,
      child: Card(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(stat.icon, color: theme.colorScheme.primary),
              const SizedBox(height: 12),
              Text(
                stat.value,
                style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              Text(stat.label, style: theme.textTheme.bodyMedium),
            ],
          ),
        ),
      ),
    );
  }
}

class _InstructorStat {
  const _InstructorStat({required this.label, required this.value, required this.icon});

  final String label;
  final String value;
  final IconData icon;
}

class _InstructorClassAssignment {
  const _InstructorClassAssignment({
    required this.id,
    required this.subjectCode,
    required this.subjectName,
    this.section,
    this.term,
    this.departmentName,
    required this.schedules,
  });

  final String id;
  final String subjectCode;
  final String subjectName;
  final String? section;
  final String? term;
  final String? departmentName;
  final List<_InstructorSchedule> schedules;

  static _InstructorClassAssignment? fromDocument(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final Map<String, dynamic>? data = doc.data();
    if (data == null) return null;
    final String subjectCode = (data['subjectCode'] as String?) ?? 'N/A';
    final String subjectName = (data['subjectName'] as String?) ?? 'Untitled Subject';
    final String? section = (data['section'] as String?)?.trim();
    final String? term = (data['term'] as String?)?.trim();
    final String? departmentName = (data['departmentName'] as String?)?.trim();
    final List<dynamic> rawSchedules = data['schedules'] as List<dynamic>? ?? <dynamic>[];

    final List<_InstructorSchedule> schedules = rawSchedules
        .map((dynamic item) => _InstructorSchedule.fromMap(
              classId: doc.id,
              data: item as Map<String, dynamic>?,
              subjectCode: subjectCode,
              subjectName: subjectName,
              section: section,
              term: term,
              departmentName: departmentName,
            ))
        .whereType<_InstructorSchedule>()
        .toList();

    return _InstructorClassAssignment(
      id: doc.id,
      subjectCode: subjectCode,
      subjectName: subjectName,
      section: section,
      term: term,
      departmentName: departmentName,
      schedules: schedules,
    );
  }
}

class _InstructorSchedule {
  const _InstructorSchedule({
    required this.classId,
    required this.subjectCode,
    required this.subjectName,
    this.section,
    this.term,
    this.departmentName,
    this.scheduleType,
    this.location,
    required this.dayOfWeek,
    required this.start,
    required this.end,
  });

  final String classId;
  final String subjectCode;
  final String subjectName;
  final String? section;
  final String? term;
  final String? departmentName;
  final String? scheduleType;
  final String? location;
  final int dayOfWeek;
  final TimeOfDay start;
  final TimeOfDay end;

  static _InstructorSchedule? fromMap({
    required String classId,
    required Map<String, dynamic>? data,
    required String subjectCode,
    required String subjectName,
    String? section,
    String? term,
    String? departmentName,
  }) {
    if (data == null) return null;
    final int? weekday = _dayStringToWeekday(data['day'] as String?);
    if (weekday == null) return null;
    final TimeOfDay? startTime = _timeFromMap(data['startTime'] as Map<String, dynamic>?);
    final TimeOfDay? endTime = _timeFromMap(data['endTime'] as Map<String, dynamic>?);
    if (startTime == null || endTime == null) return null;
    final String? room = (data['room'] as String?)?.trim();
    final String? type = (data['type'] as String?)?.trim();

    return _InstructorSchedule(
      classId: classId,
      subjectCode: subjectCode,
      subjectName: subjectName,
      section: section,
      term: term,
      departmentName: departmentName,
      scheduleType: type,
      location: room?.isEmpty ?? true ? null : room,
      dayOfWeek: weekday,
      start: startTime,
      end: endTime,
    );
  }

  static int compareByDayAndTime(_InstructorSchedule a, _InstructorSchedule b) {
    final int dayCompare = a.dayOfWeek.compareTo(b.dayOfWeek);
    if (dayCompare != 0) return dayCompare;
    final int hourCompare = a.start.hour.compareTo(b.start.hour);
    if (hourCompare != 0) return hourCompare;
    return a.start.minute.compareTo(b.start.minute);
  }

  bool isActive(DateTime reference) {
    if (dayOfWeek != reference.weekday) return false;
    final DateTime startDate = DateTime(
      reference.year,
      reference.month,
      reference.day,
      start.hour,
      start.minute,
    );
    final DateTime endDate = DateTime(
      reference.year,
      reference.month,
      reference.day,
      end.hour,
      end.minute,
    );
    return !reference.isBefore(startDate) && reference.isBefore(endDate);
  }

  Duration timeUntilStart(DateTime reference) {
    DateTime nextOccurrence = _startDateFrom(reference);
    if (nextOccurrence.isBefore(reference)) {
      nextOccurrence = nextOccurrence.add(const Duration(days: 7));
    }
    return nextOccurrence.difference(reference);
  }

  DateTime _startDateFrom(DateTime reference) {
    int weekdayDelta = dayOfWeek - reference.weekday;
    if (weekdayDelta < 0) {
      weekdayDelta += 7;
    }
    final DateTime base = DateTime(reference.year, reference.month, reference.day).add(
      Duration(days: weekdayDelta),
    );
    return DateTime(base.year, base.month, base.day, start.hour, start.minute);
  }

  static TimeOfDay? _timeFromMap(Map<String, dynamic>? data) {
    if (data == null) return null;
    final int? hourRaw = (data['hour'] as num?)?.toInt();
    final int minute = (data['minute'] as num?)?.toInt() ?? 0;
    final String period = ((data['period'] as String?) ?? 'AM').toUpperCase();
    if (hourRaw == null) return null;
    int normalizedHour = hourRaw % 12;
    if (period == 'PM') {
      normalizedHour += 12;
    }
    final int safeMinute = minute.clamp(0, 59).toInt();
    return TimeOfDay(hour: normalizedHour, minute: safeMinute);
  }

  static int? _dayStringToWeekday(String? value) {
    switch ((value ?? '').toLowerCase()) {
      case 'monday':
        return DateTime.monday;
      case 'tuesday':
        return DateTime.tuesday;
      case 'wednesday':
        return DateTime.wednesday;
      case 'thursday':
        return DateTime.thursday;
      case 'friday':
        return DateTime.friday;
      case 'saturday':
        return DateTime.saturday;
      case 'sunday':
        return DateTime.sunday;
      default:
        return null;
    }
  }
}
