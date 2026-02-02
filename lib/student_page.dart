import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import 'face_enrollment_page.dart';
import 'services/excuse_request_service.dart';
import 'widgets/confirm_sign_out_dialog.dart';
import 'widgets/request_excuse_dialog.dart';

class StudentPage extends StatefulWidget {
  const StudentPage({super.key});

  static const String routeName = '/student';

  @override
  State<StudentPage> createState() => _StudentPageState();
}

class _StudentPageState extends State<StudentPage> {
  Future<void> _handleSignOut() async {
    final bool shouldSignOut = await showConfirmSignOutDialog(context);
    if (!shouldSignOut) return;
    if (!mounted) return;

    try {
      await FirebaseAuth.instance.signOut();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to sign out. Please try again.'),
          ),
        );
      }
      return;
    }

    if (mounted) {
      Navigator.of(context)
          .pushNamedAndRemoveUntil('/login', (Route<dynamic> route) => false);
    }
  }

  Future<void> _launchEnrollment() async {
    await Navigator.of(context).pushNamed(FaceEnrollmentPage.routeName);
  }

  @override
  Widget build(BuildContext context) {
    final User? user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return const Scaffold(
        body: Center(child: Text('No authenticated user found.')),
      );
    }
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .snapshots(),
      builder: (BuildContext context,
          AsyncSnapshot<DocumentSnapshot<Map<String, dynamic>>> snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.hasError) {
          return Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Unable to load your profile: ${snapshot.error}',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          );
        }
        final Map<String, dynamic>? data = snapshot.data?.data();
        final List<dynamic>? faceEmbeds = data?['faceEmbeds'] as List<dynamic>?;
        final List<dynamic>? faceEmbed = data?['faceEmbed'] as List<dynamic>?;
        final bool hasEnrollment =
          (faceEmbeds != null && faceEmbeds.isNotEmpty) ||
          (faceEmbed != null && faceEmbed.isNotEmpty);

        if (!hasEnrollment) {
          return _FaceEnrollmentRequiredView(
            onSignOut: () => _handleSignOut(),
            onStartEnrollment: () => _launchEnrollment(),
          );
        }

        final _StudentProfile profile = _StudentProfile(
          userId: user.uid,
          displayName: _resolveDisplayName(data, user),
          section: (data?['section'] as String?)?.trim() ?? '',
          term: (data?['currentTerm'] as String?) ?? (data?['term'] as String?),
          studentId: _resolveStudentId(data, user),
        );

        return _StudentDashboard(
          profile: profile,
          onSignOut: () => _handleSignOut(),
        );
      },
    );
  }

  String _resolveDisplayName(Map<String, dynamic>? data, User user) {
    return (data?['displayName'] as String?) ??
        (data?['Full Name'] as String?) ??
        user.displayName ??
        'Student';
  }

  String _resolveStudentId(Map<String, dynamic>? data, User user) {
    final dynamic raw = data?['studentId'] ?? data?['StudentId'] ?? data?['Student ID'];
    if (raw is String && raw.trim().isNotEmpty) {
      return raw.trim();
    }
    return user.uid;
  }
}

class _FaceEnrollmentRequiredView extends StatelessWidget {
  const _FaceEnrollmentRequiredView({
    required this.onStartEnrollment,
    required this.onSignOut,
  });

  final VoidCallback onStartEnrollment;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Complete enrollment')),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            return Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      const Icon(Icons.face_retouching_natural, size: 72),
                      const SizedBox(height: 16),
                      Text(
                        'Before accessing the dashboard we need to capture your facial embedding for secure attendance.',
                        style: theme.textTheme.titleMedium,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: onStartEnrollment,
                          icon: const Icon(Icons.camera_alt_outlined),
                          label: const Text('Start face enrollment'),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextButton(
                        onPressed: onSignOut,
                        child: const Text('Sign out'),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _StudentDashboard extends StatefulWidget {
  const _StudentDashboard({required this.profile, required this.onSignOut});

  final _StudentProfile profile;
  final VoidCallback onSignOut;

  @override
  State<_StudentDashboard> createState() => _StudentDashboardState();
}

class _StudentDashboardState extends State<_StudentDashboard> {
  late Future<_StudentDashboardData> _dashboardFuture;
  final ExcuseRequestService _excuseService = ExcuseRequestService();

  bool _summaryLoading = true;
  Object? _summaryError;
  _StudentAttendanceSummary _summary = const _StudentAttendanceSummary(isLoading: true);
  final Map<String, _StudentAttendanceSummary> _statsByClassId =
      <String, _StudentAttendanceSummary>{};

  @override
  void initState() {
    super.initState();
    _dashboardFuture = _loadDashboardData();
  }

  @override
  void didUpdateWidget(covariant _StudentDashboard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.profile.userId != widget.profile.userId ||
        oldWidget.profile.section != widget.profile.section) {
      _statsByClassId.clear();
      _summaryError = null;
      _summaryLoading = true;
      _summary = const _StudentAttendanceSummary(isLoading: true);
      _dashboardFuture = _loadDashboardData();
    }
  }

  Future<_StudentDashboardData> _loadDashboardData() async {
    if (widget.profile.section.isEmpty) {
      _setSummaryIdle(const _StudentAttendanceSummary());
      return const _StudentDashboardData(
        assignments: <_StudentClassAssignment>[],
        resolvedTerm: null,
      );
    }

    Query<Map<String, dynamic>> query = FirebaseFirestore.instance
        .collection('classes')
        .where('section', isEqualTo: widget.profile.section);
    final QuerySnapshot<Map<String, dynamic>> snapshot = await query.get();

    final List<_StudentClassAssignment> assignments = snapshot.docs
        .map(_buildAssignmentFromClassDoc)
        .whereType<_StudentClassAssignment>()
        .toList()
      ..sort((a, b) => a.subjectCode.compareTo(b.subjectCode));

    final Iterable<String> termValues = assignments
        .map(( _StudentClassAssignment assignment) => assignment.term.trim())
        .where((String term) => term.isNotEmpty);
    final Set<String> uniqueTerms = termValues.toSet();
    final String? resolvedTerm = uniqueTerms.isEmpty
        ? widget.profile.term
        : uniqueTerms.length == 1
            ? uniqueTerms.first
            : 'Multiple terms';

    // Do not block the whole dashboard on per-class stats reads.
    _loadAttendanceSummary(assignments);

    return _StudentDashboardData(assignments: assignments, resolvedTerm: resolvedTerm);
  }

  _StudentClassAssignment? _buildAssignmentFromClassDoc(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final Map<String, dynamic> data = doc.data();
    final List<_StudentClassSchedule> schedules =
        (data['schedules'] as List<dynamic>? ?? <dynamic>[])
            .map(
              (dynamic entry) => _StudentClassSchedule.fromMap(
                entry as Map<String, dynamic>?,
              ),
            )
            .whereType<_StudentClassSchedule>()
            .toList();
    return _StudentClassAssignment(
      id: doc.id,
      subjectCode: (data['subjectCode'] as String?) ?? 'N/A',
      subjectName: (data['subjectName'] as String?) ?? 'Untitled Subject',
      section: (data['section'] as String?) ?? '',
      term: (data['term'] as String?) ?? '',
      departmentName: (data['departmentName'] as String?) ?? '',
      schedules: schedules,
    );
  }

  void _setSummaryIdle(_StudentAttendanceSummary summary) {
    if (!mounted) return;
    setState(() {
      _summaryLoading = false;
      _summaryError = null;
      _summary = summary;
    });
  }

  Future<void> _loadAttendanceSummary(List<_StudentClassAssignment> assignments) async {
    if (assignments.isEmpty) {
      _setSummaryIdle(const _StudentAttendanceSummary());
      return;
    }

    if (!mounted) return;
    setState(() {
      _summaryLoading = true;
      _summaryError = null;
      _summary = const _StudentAttendanceSummary(isLoading: true);
    });

    final String studentId = widget.profile.userId;

    try {
      final List<Future<_StudentAttendanceSummary>> reads = assignments.map((a) async {
        final _StudentAttendanceSummary? cached = _statsByClassId[a.id];
        if (cached != null) return cached;

        final DocumentSnapshot<Map<String, dynamic>> statsDoc = await FirebaseFirestore
            .instance
            .collection('classes')
            .doc(a.id)
            .collection('attendanceStats')
            .doc(studentId)
            .get();
        final _StudentAttendanceSummary stats =
            _StudentAttendanceSummary.fromMap(statsDoc.data());
        _statsByClassId[a.id] = stats;
        return stats;
      }).toList();

      final List<_StudentAttendanceSummary> statsList = await Future.wait(reads);
      final _StudentAttendanceSummary summary = statsList.fold<_StudentAttendanceSummary>(
        const _StudentAttendanceSummary(),
        (_StudentAttendanceSummary total, _StudentAttendanceSummary other) => total + other,
      );

      if (!mounted) return;
      setState(() {
        _summaryLoading = false;
        _summaryError = null;
        _summary = summary;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _summaryLoading = false;
        _summaryError = error;
        _summary = const _StudentAttendanceSummary();
      });
    }
  }

  Future<void> _handleRefresh() async {
    _statsByClassId.clear();
    _summaryError = null;
    _summaryLoading = true;
    _summary = const _StudentAttendanceSummary(isLoading: true);
    final Future<_StudentDashboardData> refreshFuture = _loadDashboardData();
    setState(() {
      _dashboardFuture = refreshFuture;
    });
    await refreshFuture;
  }

  Future<void> _openRequestExcuseDialog() async {
    final bool? submitted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return RequestExcuseDialog(excuseService: _excuseService);
      },
    );

    if (!mounted) return;
    if (submitted == true) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Excuse request submitted.')),
      );
    }
  }

  Future<void> _openPdfFromAttachment(Map<String, dynamic>? attachment) async {
    if (attachment == null) return;
    final String path = (attachment['path'] as String?) ?? '';
    if (path.isEmpty) return;
    try {
      final Uint8List bytes = await _excuseService.downloadPdfBytes(path: path);
      await Printing.layoutPdf(onLayout: (_) async => bytes);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unable to open PDF: $error')),
      );
    }
  }

  Widget _buildExcuseRequestsCard(ThemeData theme) {
    final String uid = widget.profile.userId;

    bool isIndexError(Object error) {
      final String message = error.toString().toLowerCase();
      return message.contains('failed-precondition') && message.contains('index');
    }

    Widget buildList(List<QueryDocumentSnapshot<Map<String, dynamic>>> docs) {
      docs.sort((a, b) {
        final Timestamp? aCreated = a.data()['createdAt'] as Timestamp?;
        final Timestamp? bCreated = b.data()['createdAt'] as Timestamp?;
        final int aMs = aCreated?.millisecondsSinceEpoch ?? 0;
        final int bMs = bCreated?.millisecondsSinceEpoch ?? 0;
        return bMs.compareTo(aMs);
      });

      return Column(
        children: docs.map((QueryDocumentSnapshot<Map<String, dynamic>> doc) {
          final Map<String, dynamic> data = doc.data();
          final String status = (data['status'] as String?) ?? 'pending';
          final String reason = (data['reason'] as String?) ?? '';
          final List<dynamic> dateKeys =
              (data['dateKeys'] as List<dynamic>?) ?? <dynamic>[];
          final String dateLabel =
              dateKeys.isEmpty ? 'No dates' : dateKeys.join(', ');
          final Map<String, dynamic>? attachment =
              (data['attachment'] as Map?)?.cast<String, dynamic>();

          return ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(
              dateLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: reason.isEmpty
                ? null
                : Text(
                    reason,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
            trailing: Wrap(
              spacing: 8,
              children: <Widget>[
                Chip(label: Text(status.toUpperCase())),
                IconButton(
                  tooltip: 'Open PDF',
                  onPressed: attachment == null
                      ? null
                      : () => _openPdfFromAttachment(attachment),
                  icon: const Icon(Icons.picture_as_pdf_outlined),
                ),
              ],
            ),
          );
        }).toList(),
      );
    }

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Excuse requests',
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: FirebaseFirestore.instance
                  .collection('excuseRequests')
                  .where('studentId', isEqualTo: uid)
                  .orderBy('createdAt', descending: true)
                  .limit(5)
                  .snapshots(),
              builder: (
                BuildContext context,
                AsyncSnapshot<QuerySnapshot<Map<String, dynamic>>> snapshot,
              ) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: LinearProgressIndicator(),
                  );
                }
                if (snapshot.hasError) {
                  final Object error = snapshot.error!;
                  if (isIndexError(error)) {
                    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                      stream: FirebaseFirestore.instance
                          .collection('excuseRequests')
                          .where('studentId', isEqualTo: uid)
                          .limit(25)
                          .snapshots(),
                      builder: (
                        BuildContext context,
                        AsyncSnapshot<QuerySnapshot<Map<String, dynamic>>>
                            fallbackSnapshot,
                      ) {
                        if (fallbackSnapshot.connectionState ==
                            ConnectionState.waiting) {
                          return const Padding(
                            padding: EdgeInsets.symmetric(vertical: 12),
                            child: LinearProgressIndicator(),
                          );
                        }
                        if (fallbackSnapshot.hasError) {
                          return Text(
                            'Failed to load requests: ${fallbackSnapshot.error}',
                          );
                        }
                        final List<
                                QueryDocumentSnapshot<Map<String, dynamic>>>
                            docs = fallbackSnapshot.data?.docs ??
                                <QueryDocumentSnapshot<Map<String, dynamic>>>[];
                        if (docs.isEmpty) {
                          return const Text('No requests yet.');
                        }
                        return buildList(docs);
                      },
                    );
                  }

                  return Text('Failed to load requests: ${snapshot.error}');
                }

                final List<QueryDocumentSnapshot<Map<String, dynamic>>> docs =
                    snapshot.data?.docs ??
                        <QueryDocumentSnapshot<Map<String, dynamic>>>[];
                if (docs.isEmpty) {
                  return const Text('No requests yet.');
                }
                return buildList(docs);
              },
            ),
          ],
        ),
      ),
    );
  }

  List<_ClassScheduleMatch> _computeUpcomingSessions(
    List<_StudentClassAssignment> assignments,
    DateTime now,
  ) {
    final List<_ClassScheduleMatch> matches = <_ClassScheduleMatch>[];
    for (final _StudentClassAssignment assignment in assignments) {
      for (final _StudentClassSchedule schedule in assignment.schedules) {
        matches.add(
          _ClassScheduleMatch(
            assignment: assignment,
            schedule: schedule,
            startTime: schedule.nextOccurrence(now),
          ),
        );
      }
    }
    matches.sort((a, b) => a.startTime.compareTo(b.startTime));
    return matches;
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Student'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Sign out',
            onPressed: widget.onSignOut,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: SafeArea(
        child: FutureBuilder<_StudentDashboardData>(
          future: _dashboardFuture,
          builder: (
            BuildContext context,
            AsyncSnapshot<_StudentDashboardData> snapshot,
          ) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Center(
                child: Text('Failed to load dashboard: ${snapshot.error}'),
              );
            }

            final _StudentDashboardData data = snapshot.data ??
                const _StudentDashboardData(
                  assignments: <_StudentClassAssignment>[],
                  resolvedTerm: null,
                );
            final DateTime now = DateTime.now();
            final List<_ClassScheduleMatch> upcomingSessions =
                _computeUpcomingSessions(data.assignments, now);
            final _ClassScheduleMatch? nextSession =
                upcomingSessions.isEmpty ? null : upcomingSessions.first;
            final List<_ClassScheduleMatch> upcomingList =
                upcomingSessions.take(3).toList();

            return RefreshIndicator(
              onRefresh: _handleRefresh,
              child: ListView(
                padding: const EdgeInsets.all(24),
                physics: const AlwaysScrollableScrollPhysics(),
                children: <Widget>[
                  _DashboardHeroCard(
                    theme: theme,
                    profile: widget.profile,
                    summary: _summary,
                    nextSession: nextSession,
                  ),
                  const SizedBox(height: 24),
                  _StudentStatsRow(
                    theme: theme,
                    summary: _summary,
                    isLoading: _summaryLoading,
                    error: _summaryError,
                  ),
                  const SizedBox(height: 24),
                  _StudentProfileSection(
                    profile: widget.profile,
                    resolvedTerm: data.resolvedTerm,
                  ),
                  const SizedBox(height: 24),
                  _StudentNextClassSection(
                    theme: theme,
                    nextSession: nextSession,
                  ),
                  const SizedBox(height: 24),
                  if (data.assignments.isEmpty)
                    _StudentEmptyClassesCard(section: widget.profile.section)
                  else
                    _StudentUpcomingList(theme: theme, sessions: upcomingList),
                  const SizedBox(height: 24),
                  _StudentActionRow(
                    theme: theme,
                    onRequestExcuse: _openRequestExcuseDialog,
                  ),
                  const SizedBox(height: 24),
                  _buildExcuseRequestsCard(theme),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _DashboardHeroCard extends StatelessWidget {
  const _DashboardHeroCard({
    required this.theme,
    required this.profile,
    required this.summary,
    this.nextSession,
  });

  final ThemeData theme;
  final _StudentProfile profile;
  final _StudentAttendanceSummary summary;
  final _ClassScheduleMatch? nextSession;

  @override
  Widget build(BuildContext context) {
    final String greeting = 'Hello, ${profile.displayName.split(' ').first}!';
    final int totalSessions = summary.total;
    final String progressText = summary.isLoading
      ? 'Loading your attendance summary...'
      : totalSessions == 0
        ? 'No recorded sessions yet. Attend your next class to get started.'
        : 'You have $totalSessions recorded sessions this term. Keep it up!';
    final String nextLabel = nextSession == null
        ? 'No upcoming classes.'
        : '${nextSession!.assignment.subjectCode} • ${nextSession!.assignment.subjectName}';
    final String nextDetails = nextSession == null
        ? 'We will let you know once a class is scheduled.'
        : '${nextSession!.schedule.formatRange(context)} • ${nextSession!.schedule.location ?? 'Location TBD'}';
    final Duration countdown = nextSession == null
        ? Duration.zero
        : nextSession!.startTime.difference(DateTime.now());

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    greeting,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(progressText, style: theme.textTheme.bodyMedium),
                  const SizedBox(height: 16),
                  Text(
                    nextLabel,
                    style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(nextDetails, style: theme.textTheme.bodySmall),
                  if (nextSession != null) ...<Widget>[
                    const SizedBox(height: 8),
                    Chip(
                      avatar: const Icon(Icons.schedule_outlined, size: 18),
                      label: Text(countdown.isNegative
                          ? 'In progress'
                          : 'Starts in ${_formatCountdown(countdown)}'),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 16),
            Icon(Icons.verified_user, size: 64, color: theme.colorScheme.primary),
          ],
        ),
      ),
    );
  }
}

class _StudentStatsRow extends StatelessWidget {
  const _StudentStatsRow({
    required this.theme,
    required this.summary,
    required this.isLoading,
    required this.error,
  });

  final ThemeData theme;
  final _StudentAttendanceSummary summary;
  final bool isLoading;
  final Object? error;

  @override
  Widget build(BuildContext context) {
    if (error != null) {
      return Row(
        children: <Widget>[
          Icon(Icons.warning_amber_rounded, color: theme.colorScheme.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Attendance summary unavailable.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
        ],
      );
    }

    final List<_StudentStat> stats = <_StudentStat>[
      _StudentStat(
        label: 'Present',
        value: isLoading ? '—' : summary.present.toString(),
      ),
      _StudentStat(label: 'Late', value: isLoading ? '—' : summary.late.toString()),
      _StudentStat(label: 'Absent', value: isLoading ? '—' : summary.absent.toString()),
    ];
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: stats
          .map(( _StudentStat stat) => _StudentStatChip(stat: stat))
          .toList(),
    );
  }
}

class _StudentProfileSection extends StatelessWidget {
  const _StudentProfileSection({required this.profile, this.resolvedTerm});

  final _StudentProfile profile;
  final String? resolvedTerm;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String sectionLabel = profile.section.isEmpty ? 'Not assigned' : profile.section;
    final String? rawTerm = (resolvedTerm?.isNotEmpty == true)
        ? resolvedTerm
        : profile.term;
    final String termLabel = rawTerm?.isNotEmpty == true ? rawTerm! : 'Not set';

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Profile', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 16),
            _ProfileRow(label: 'Name', value: profile.displayName),
            const SizedBox(height: 12),
            _ProfileRow(label: 'Section', value: sectionLabel),
            const SizedBox(height: 12),
            _ProfileRow(label: 'Current term', value: termLabel),
            const SizedBox(height: 12),
            _ProfileRow(label: 'Student ID', value: profile.studentId),
          ],
        ),
      ),
    );
  }
}

class _ProfileRow extends StatelessWidget {
  const _ProfileRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 120,
          child: Text(label, style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.outline)),
        ),
        Expanded(
          child: Text(value, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w500)),
        ),
      ],
    );
  }
}

class _StudentStat {
  const _StudentStat({required this.label, required this.value});
  final String label;
  final String value;
}

class _StudentStatChip extends StatelessWidget {
  const _StudentStatChip({required this.stat});
  final _StudentStat stat;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return SizedBox(
      width: 110,
      child: Card(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                stat.value,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              Text(stat.label, style: theme.textTheme.labelLarge),
            ],
          ),
        ),
      ),
    );
  }
}

class _StudentNextClassSection extends StatelessWidget {
  const _StudentNextClassSection({required this.theme, this.nextSession});

  final ThemeData theme;
  final _ClassScheduleMatch? nextSession;

  void _showSessionDetailsDialog(BuildContext context, _ClassScheduleMatch session) {
    // Schedule dialog display after the current frame. This avoids Flutter
    // assertions like "Tried to build dirty widget in the wrong build scope"
    // when the tap occurs during an in-progress rebuild.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!context.mounted) return;

      final MaterialLocalizations localizations =
          MaterialLocalizations.of(context);
      final String dateLabel = localizations.formatFullDate(session.startTime);
      final String timeLabel = localizations.formatTimeOfDay(
        TimeOfDay.fromDateTime(session.startTime),
        alwaysUse24HourFormat: false,
      );

      showDialog<void>(
        context: context,
        useRootNavigator: true,
        builder: (BuildContext dialogContext) {
          return AlertDialog(
            title: const Text('Session details'),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '${session.assignment.subjectCode} • ${session.assignment.subjectName}',
                    style: Theme.of(dialogContext)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Schedule: ${session.schedule.formatRange(dialogContext)}',
                  ),
                  Text(
                    'Location: ${session.schedule.location ?? 'Location TBD'}',
                  ),
                  const SizedBox(height: 12),
                  Text('Next start: $dateLabel • $timeLabel'),
                ],
              ),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Close'),
              ),
            ],
          );
        },
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    if (nextSession == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('Next session', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            child: const ListTile(
              leading: Icon(Icons.hourglass_empty_outlined),
              title: Text('No sessions detected for your section.'),
              subtitle: Text('Check back later or ask your instructor for the latest schedule.'),
            ),
          ),
        ],
      );
    }

    final Duration countdown = nextSession!.startTime.difference(DateTime.now());
    final String countdownLabel = countdown.isNegative
        ? 'In progress'
        : 'Starts in ${_formatCountdown(countdown)}';

    final double screenWidth = MediaQuery.sizeOf(context).width;
    final bool isNarrow = screenWidth < 380;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('Next session', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        Card(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: theme.colorScheme.primaryContainer,
              child: Icon(Icons.class_outlined, color: theme.colorScheme.primary),
            ),
            title: Text(
              '${nextSession!.assignment.subjectCode} • ${nextSession!.assignment.subjectName}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '${nextSession!.schedule.formatRange(context)} • ${nextSession!.schedule.location ?? 'Location TBD'}\n$countdownLabel',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: isNarrow
                ? IconButton.filledTonal(
                    tooltip: 'Details',
                    onPressed: () =>
                        _showSessionDetailsDialog(context, nextSession!),
                    icon: const Icon(Icons.route_outlined),
                  )
                : FilledButton.tonalIcon(
                    onPressed: () =>
                        _showSessionDetailsDialog(context, nextSession!),
                    icon: const Icon(Icons.route_outlined),
                    label: const Text('Details'),
                  ),
          ),
        ),
      ],
    );
  }
}

class _StudentUpcomingList extends StatelessWidget {
  const _StudentUpcomingList({required this.theme, required this.sessions});

  final ThemeData theme;
  final List<_ClassScheduleMatch> sessions;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'Upcoming classes',
          style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 12),
        if (sessions.isEmpty)
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: const ListTile(
              leading: Icon(Icons.event_busy_outlined),
              title: Text('No other sessions scheduled.'),
              subtitle: Text('We will show the next classes once they are available.'),
            ),
          )
        else
          ...sessions.map(( _ClassScheduleMatch match) => _StudentScheduleTile(match: match)),
      ],
    );
  }
}

class _StudentEmptyClassesCard extends StatelessWidget {
  const _StudentEmptyClassesCard({required this.section});

  final String section;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'No classes assigned',
              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              section.isEmpty
                  ? 'Your account has not been linked to a section yet. Please reach out to your instructor.'
                  : 'We could not find any classes for section "$section". Please check with your instructor.',
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class _StudentActionRow extends StatelessWidget {
  const _StudentActionRow({
    required this.theme,
    required this.onRequestExcuse,
  });

  final ThemeData theme;
  final VoidCallback onRequestExcuse;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('Quick actions', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: <Widget>[
            FilledButton.icon(
              onPressed: onRequestExcuse,
              icon: const Icon(Icons.report_problem_outlined),
              label: const Text('Request excuse'),
            ),
            OutlinedButton.icon(
              onPressed: () {},
              icon: const Icon(Icons.history_outlined),
              label: const Text('View attendance log'),
            ),
          ],
        ),
      ],
    );
  }
}

class _StudentScheduleTile extends StatelessWidget {
  const _StudentScheduleTile({required this.match});

  final _ClassScheduleMatch match;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Duration countdown = match.startTime.difference(DateTime.now());
    final String countdownLabel = countdown.isNegative
        ? 'In progress'
        : 'Starts in ${_formatCountdown(countdown)}';

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ListTile(
        leading: const Icon(Icons.calendar_today_outlined),
        title: Text('${match.assignment.subjectCode} • ${match.assignment.subjectName}'),
        subtitle: Text(
          '${match.schedule.formatRange(context)} • ${match.schedule.location ?? 'Location TBD'}',
        ),
        trailing: Text(
          countdownLabel,
          style: theme.textTheme.labelMedium,
          textAlign: TextAlign.right,
        ),
      ),
    );
  }
}

class _StudentProfile {
  const _StudentProfile({
    required this.userId,
    required this.displayName,
    required this.section,
    required this.studentId,
    this.term,
  });

  final String userId;
  final String displayName;
  final String section;
  final String studentId;
  final String? term;
}

class _StudentDashboardData {
  const _StudentDashboardData({
    required this.assignments,
    required this.resolvedTerm,
  });

  final List<_StudentClassAssignment> assignments;
  final String? resolvedTerm;
}

class _StudentClassAssignment {
  const _StudentClassAssignment({
    required this.id,
    required this.subjectCode,
    required this.subjectName,
    required this.section,
    required this.term,
    required this.departmentName,
    required this.schedules,
  });

  final String id;
  final String subjectCode;
  final String subjectName;
  final String section;
  final String term;
  final String departmentName;
  final List<_StudentClassSchedule> schedules;
}

class _StudentClassSchedule {
  const _StudentClassSchedule({
    required this.weekday,
    required this.startTime,
    required this.endTime,
    this.location,
  });

  final int weekday;
  final TimeOfDay startTime;
  final TimeOfDay endTime;
  final String? location;

  static _StudentClassSchedule? fromMap(Map<String, dynamic>? data) {
    if (data == null) {
      return null;
    }
    final int? weekday = _weekdayFromValue(data['day'] ?? data['dayOfWeek']);
    final TimeOfDay? start = _resolveScheduleTime(data['start'] ?? data['startTime']);
    final TimeOfDay? end = _resolveScheduleTime(data['end'] ?? data['endTime']);
    if (weekday == null || start == null || end == null) {
      return null;
    }
    final String? location = ((data['location'] ?? data['room']) as String?)?.trim();
    return _StudentClassSchedule(
      weekday: weekday,
      startTime: start,
      endTime: end,
      location: (location == null || location.isEmpty) ? null : location,
    );
  }

  DateTime nextOccurrence(DateTime reference) {
    DateTime occurrence = DateTime(
      reference.year,
      reference.month,
      reference.day,
      startTime.hour,
      startTime.minute,
    );
    int dayOffset = (weekday - occurrence.weekday) % 7;
    if (dayOffset < 0) {
      dayOffset += 7;
    }
    occurrence = occurrence.add(Duration(days: dayOffset));
    if (occurrence.isBefore(reference)) {
      occurrence = occurrence.add(const Duration(days: 7));
    }
    return occurrence;
  }

  String formatRange(BuildContext context) {
    final String startLabel = startTime.format(context);
    final String endLabel = endTime.format(context);
    return '${_weekdayLabel(weekday)} • $startLabel - $endLabel';
  }
}

class _ClassScheduleMatch {
  const _ClassScheduleMatch({
    required this.assignment,
    required this.schedule,
    required this.startTime,
  });

  final _StudentClassAssignment assignment;
  final _StudentClassSchedule schedule;
  final DateTime startTime;
}

class _StudentAttendanceSummary {
  const _StudentAttendanceSummary({
    this.present = 0,
    this.late = 0,
    this.absent = 0,
    this.isLoading = false,
  });

  final int present;
  final int late;
  final int absent;
  final bool isLoading;

  int get total => present + late + absent;

  factory _StudentAttendanceSummary.fromMap(Map<String, dynamic>? data) {
    if (data == null) {
      return const _StudentAttendanceSummary();
    }

    int readCount(String primary, String fallback) {
      final num? a = data[primary] as num?;
      if (a != null) return a.toInt();
      final num? b = data[fallback] as num?;
      return b?.toInt() ?? 0;
    }

    return _StudentAttendanceSummary(
      // Older schema: present/late/absent
      // Current schema used by attendance_session_page.dart: presentCount/lateCount/absentCount
      present: readCount('present', 'presentCount'),
      late: readCount('late', 'lateCount'),
      absent: readCount('absent', 'absentCount'),
    );
  }

  _StudentAttendanceSummary operator +(_StudentAttendanceSummary other) {
    return _StudentAttendanceSummary(
      present: present + other.present,
      late: late + other.late,
      absent: absent + other.absent,
    );
  }
}

String _formatCountdown(Duration duration) {
  final Duration positive = duration.isNegative ? Duration.zero : duration;
  final int days = positive.inDays;
  final int hours = positive.inHours.remainder(24);
  final int minutes = positive.inMinutes.remainder(60);
  final List<String> parts = <String>[];
  if (days > 0) {
    parts.add('${days}d');
  }
  if (hours > 0) {
    parts.add('${hours}h');
  }
  if (minutes > 0 && parts.length < 2) {
    parts.add('${minutes}m');
  }
  if (parts.isEmpty) {
    return 'a few moments';
  }
  return parts.join(' ');
}

int? _weekdayFromValue(dynamic value) {
  if (value == null) {
    return null;
  }
  if (value is int && value >= 1 && value <= 7) {
    return value;
  }
  final String normalized = value.toString().trim().toLowerCase();
  const Map<String, int> names = <String, int>{
    'monday': DateTime.monday,
    'mon': DateTime.monday,
    'tuesday': DateTime.tuesday,
    'tue': DateTime.tuesday,
    'wednesday': DateTime.wednesday,
    'wed': DateTime.wednesday,
    'thursday': DateTime.thursday,
    'thu': DateTime.thursday,
    'friday': DateTime.friday,
    'fri': DateTime.friday,
    'saturday': DateTime.saturday,
    'sat': DateTime.saturday,
    'sunday': DateTime.sunday,
    'sun': DateTime.sunday,
  };
  return names[normalized];
}

String _weekdayLabel(int weekday) {
  switch (weekday) {
    case DateTime.monday:
      return 'Mon';
    case DateTime.tuesday:
      return 'Tue';
    case DateTime.wednesday:
      return 'Wed';
    case DateTime.thursday:
      return 'Thu';
    case DateTime.friday:
      return 'Fri';
    case DateTime.saturday:
      return 'Sat';
    case DateTime.sunday:
      return 'Sun';
    default:
      return 'Day';
  }
}

TimeOfDay? _parseTimeOfDay(dynamic value) {
  if (value == null) {
    return null;
  }
  if (value is Map<String, dynamic>) {
    return _parseScheduleTimeMap(value);
  }
  if (value is TimeOfDay) {
    return value;
  }
  final String input = value.toString().trim();
  final RegExpMatch? match = RegExp(r'^(\d{1,2}):(\d{2})').firstMatch(input);
  if (match == null) {
    return null;
  }
  int hour = int.parse(match.group(1)!);
  final int minute = int.parse(match.group(2)!);
  final String upper = input.toUpperCase();
  final bool isPM = upper.contains('PM');
  final bool isAM = upper.contains('AM');
  if (isPM && hour < 12) {
    hour += 12;
  }
  if (isAM && hour == 12) {
    hour = 0;
  }
  if (!isAM && !isPM && hour == 12) {
    hour = 0;
  }
  if (hour < 0 || hour > 23 || minute < 0 || minute > 59) {
    return null;
  }
  return TimeOfDay(hour: hour, minute: minute);
}

TimeOfDay? _parseScheduleTimeMap(Map<String, dynamic>? map) {
  if (map == null) {
    return null;
  }
  final int? hourRaw = (map['hour'] as num?)?.toInt();
  final int? minute = (map['minute'] as num?)?.toInt();
  if (hourRaw == null || minute == null) {
    return null;
  }
  String? period = (map['period'] as String?)?.trim().toUpperCase();
  int hour = hourRaw;
  if (period == 'PM' && hour < 12) {
    hour += 12;
  }
  if (period == 'AM' && hour == 12) {
    hour = 0;
  }
  hour %= 24;
  if (hour < 0 || hour > 23 || minute < 0 || minute > 59) {
    return null;
  }
  return TimeOfDay(hour: hour, minute: minute);
}

TimeOfDay? _resolveScheduleTime(dynamic value) {
  if (value == null) {
    return null;
  }
  if (value is Map<String, dynamic>) {
    return _parseScheduleTimeMap(value);
  }
  return _parseTimeOfDay(value);
}
