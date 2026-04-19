import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import 'attendance_session_page.dart';
import 'widgets/android_only_feature_page.dart';
import 'offline_mode_checklist_page.dart';
import 'reports/generate_report_page.dart';
import 'services/excuse_request_service.dart';
import 'services/attendance_calendar_service.dart';
import 'services/open_external_url.dart';
import 'services/offline_mode_service.dart';
import 'services/offline_mode_service_types.dart';
import 'services/push_notification_service.dart';
import 'widgets/confirm_sign_out_dialog.dart';
import 'notifications_page.dart';

enum _InstructorSection {
  dashboard,
  attendanceSession,
  attendanceReports,
  weeklySchedule,
}

class InstructorPage extends StatefulWidget {
  const InstructorPage({super.key});

  static const String routeName = '/instructor';

  @override
  State<InstructorPage> createState() => _InstructorPageState();
}

class _InstructorPageState extends State<InstructorPage> {
  bool _simulationEnabled = true;
  late DateTime _simulatedTime;
  _InstructorSection _section = _InstructorSection.dashboard;
  bool _pushInitialized = false;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>?
  _profileSubscription;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>?
  _assignmentSubscription;
  bool _approvalLoaded = false;
  bool _isApproved = false;
  bool _isLoadingAssignments = true;
  String? _assignmentError;
  List<_InstructorClassAssignment> _assignments =
      <_InstructorClassAssignment>[];
  List<_InstructorSchedule> _scheduleEntries = <_InstructorSchedule>[];
  bool _isLaunchingSession = false;
  bool _isApprovingExcuse = false;
  final ExcuseRequestService _excuseService = ExcuseRequestService();
  final AttendanceCalendarService _calendar = AttendanceCalendarService();

  final OfflineModeService _offlineModeService = OfflineModeService();
  OfflineModeStatus? _offlineModeStatus;
  bool _offlineModeChecking = false;
  int _offlineModeRequestId = 0;

  DateTime get _activeTime =>
      _simulationEnabled ? _simulatedTime : DateTime.now();

  static const String _kSessionPointerCollection = 'attendanceSessionPointers';

  String _scheduleKeyFor({
    required int dayOfWeek,
    required TimeOfDay start,
    required TimeOfDay end,
  }) {
    String two(int n) => n.toString().padLeft(2, '0');
    final String startKey = '${two(start.hour)}${two(start.minute)}';
    final String endKey = '${two(end.hour)}${two(end.minute)}';
    return 'd$dayOfWeek-${startKey}_$endKey';
  }

  Future<bool> _confirmReopenCompletedSession(
    BuildContext context, {
    required bool expired,
  }) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Reopen completed session?'),
        content: Text(
          [
            'This session is marked as completed.',
            'Existing recorded attendance will be kept.',
            if (expired)
              'Note: the current time is past the scheduled end, so it may auto-end immediately.',
          ].join('\n\n'),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Reopen'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<bool> _reopenSessionBestEffort({
    required String sessionId,
    required String pointerId,
  }) async {
    try {
      await FirebaseFirestore.instance
          .collection('attendanceSessions')
          .doc(sessionId)
          .update(<String, dynamic>{
            'status': 'active',
            'resumedAt': FieldValue.serverTimestamp(),
            'endedAt': FieldValue.delete(),
            'effectiveEndedAt': FieldValue.delete(),
          });
    } catch (_) {
      return false;
    }

    try {
      await FirebaseFirestore.instance
          .collection(_kSessionPointerCollection)
          .doc(pointerId)
          .set(<String, dynamic>{
            'status': 'active',
            'endedAt': FieldValue.delete(),
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
    } catch (_) {
      // Best-effort only.
    }

    return true;
  }

  String _dateKey(DateTime dt) {
    final String y = dt.year.toString().padLeft(4, '0');
    final String m = dt.month.toString().padLeft(2, '0');
    final String d = dt.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  String? _pointerIdForSchedule({
    required _InstructorSchedule schedule,
    required DateTime activeTime,
  }) {
    final String? uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null || uid.isEmpty) return null;
    final String classId = schedule.classId.trim();
    if (classId.isEmpty) return null;
    return '${uid}_${classId}_${_dateKey(activeTime)}';
  }

  Future<void> _completeExpiredSessionBestEffort({
    required String sessionId,
    required String pointerId,
  }) async {
    try {
      await FirebaseFirestore.instance
          .collection('attendanceSessions')
          .doc(sessionId)
          .update(<String, dynamic>{
            'status': 'completed',
            'endedAt': FieldValue.serverTimestamp(),
          });
    } catch (_) {
      // Best-effort.
    }

    try {
      await FirebaseFirestore.instance
          .collection(_kSessionPointerCollection)
          .doc(pointerId)
          .set(<String, dynamic>{
            'status': 'completed',
            'endedAt': FieldValue.serverTimestamp(),
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
    } catch (_) {
      // Best-effort.
    }
  }

  String _sectionTitle() {
    return switch (_section) {
      _InstructorSection.dashboard => 'Dashboard',
      _InstructorSection.attendanceSession => 'Attendance session',
      _InstructorSection.attendanceReports => 'Attendance reports',
      _InstructorSection.weeklySchedule => 'Weekly schedule',
    };
  }

  IconData _sectionIcon() {
    return switch (_section) {
      _InstructorSection.dashboard => Icons.dashboard_outlined,
      _InstructorSection.attendanceSession => Icons.play_circle_outline,
      _InstructorSection.attendanceReports => Icons.insights_outlined,
      _InstructorSection.weeklySchedule => Icons.calendar_month_outlined,
    };
  }

  void _selectSection(_InstructorSection section) {
    if (!mounted) return;
    setState(() => _section = section);
    Navigator.of(context).maybePop();
  }

  Widget _buildDashboardTab(
    ThemeData theme,
    List<_InstructorStat> stats,
    bool showLoadingState,
  ) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[_buildStatsSection(theme, stats, showLoadingState)],
      ),
    );
  }

  Widget _buildAttendanceSessionTab(
    DateTime activeTime,
    _InstructorSchedule? nextSchedule,
    _InstructorSchedule? activeSchedule,
    bool showLoadingState,
    bool hasAssignments,
  ) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _buildSimulationPanel(context, activeTime),
          const SizedBox(height: 24),
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
            activeTime,
            activeSchedule,
            showLoadingState,
            _assignmentError,
            hasAssignments,
          ),
        ],
      ),
    );
  }

  Widget _buildAttendanceReportsTab(bool hasAssignments) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _buildReportShortcutCard(context, hasAssignments),
          const SizedBox(height: 32),
          _buildExcuseRequestsCard(),
        ],
      ),
    );
  }

  Widget _buildWeeklyScheduleTab(
    DateTime liveTime,
    _InstructorSchedule? nextSchedule,
    bool showLoadingState,
    bool hasAssignments,
  ) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _buildScheduleSection(
            context,
            liveTime,
            nextSchedule,
            showLoadingState,
            _assignmentError,
            hasAssignments,
          ),
        ],
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _simulatedTime = DateTime.now();
    _listenToApproval();
    _ensurePushInitialized();
  }

  void _ensurePushInitialized() {
    if (_pushInitialized) return;
    final User? user = FirebaseAuth.instance.currentUser;
    final String? uid = user?.uid;
    if (uid == null || uid.trim().isEmpty) return;
    _pushInitialized = true;
    initPushNotifications(uid: uid, role: 'instructor');
  }

  @override
  void dispose() {
    _profileSubscription?.cancel();
    _assignmentSubscription?.cancel();
    super.dispose();
  }

  Future<void> _approveExcuseRequest(String requestId) async {
    if (_isApprovingExcuse) return;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Approve excuse request?'),
        content: const Text(
          'This will immediately mark the selected absence as excused.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Approve'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _isApprovingExcuse = true);
    try {
      await _excuseService.approve(requestId: requestId);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Excuse request approved.')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Approval failed: $error')));
    } finally {
      if (mounted) setState(() => _isApprovingExcuse = false);
    }
  }

  Future<void> _disapproveExcuseRequest(String requestId) async {
    if (_isApprovingExcuse) return;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Disapprove excuse request?'),
        content: const Text(
          'This will mark the request as rejected. The student can submit a new request if needed.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Disapprove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _isApprovingExcuse = true);
    try {
      await _excuseService.disapprove(requestId: requestId);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Excuse request rejected.')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Disapprove failed: $error')));
    } finally {
      if (mounted) setState(() => _isApprovingExcuse = false);
    }
  }

  Future<void> _openPdfFromAttachment(Map<String, dynamic>? attachment) async {
    if (attachment == null) return;
    final String path = (attachment['path'] as String?) ?? '';
    if (path.isEmpty) return;
    try {
      if (kIsWeb) {
        final String? existingUrl = attachment['url'] as String?;
        final String url = (existingUrl != null && existingUrl.isNotEmpty)
            ? existingUrl
            : await _excuseService.getPdfDownloadUrl(path: path);
        final bool launched = await openExternalUrl(url);
        if (!launched) {
          throw StateError('Unable to launch PDF');
        }
        return;
      }

      final bytes = await _excuseService.downloadPdfBytes(path: path);
      await Printing.layoutPdf(onLayout: (_) async => bytes);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Unable to open PDF: $error')));
    }
  }

  Widget _buildExcuseRequestsCard() {
    final ThemeData theme = Theme.of(context);
    final User? user = FirebaseAuth.instance.currentUser;
    final String uid = user?.uid ?? '';
    if (uid.isEmpty) {
      return const SizedBox.shrink();
    }

    bool isIndexError(Object error) {
      final String message = error.toString().toLowerCase();
      return message.contains('failed-precondition') &&
          message.contains('index');
    }

    List<QueryDocumentSnapshot<Map<String, dynamic>>> sortAndFilter(
      List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
    ) {
      final List<QueryDocumentSnapshot<Map<String, dynamic>>> pending = docs
          .where((doc) {
            final Object? status = doc.data()['status'];
            return status is String && status.toLowerCase() == 'pending';
          })
          .toList();
      pending.sort((a, b) {
        final Timestamp? aCreated = a.data()['createdAt'] as Timestamp?;
        final Timestamp? bCreated = b.data()['createdAt'] as Timestamp?;
        final int aMs = aCreated?.millisecondsSinceEpoch ?? 0;
        final int bMs = bCreated?.millisecondsSinceEpoch ?? 0;
        return bMs.compareTo(aMs);
      });
      return pending;
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
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Review and approve requests from your assigned students.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: FirebaseFirestore.instance
                  .collection('excuseRequests')
                  .where('instructorIds', arrayContains: uid)
                  .where('status', isEqualTo: 'pending')
                  .orderBy('createdAt', descending: true)
                  .limit(20)
                  .snapshots(),
              builder:
                  (
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
                        return StreamBuilder<
                          QuerySnapshot<Map<String, dynamic>>
                        >(
                          stream: FirebaseFirestore.instance
                              .collection('excuseRequests')
                              .where('instructorIds', arrayContains: uid)
                              .limit(50)
                              .snapshots(),
                          builder:
                              (
                                BuildContext context,
                                AsyncSnapshot<
                                  QuerySnapshot<Map<String, dynamic>>
                                >
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
                                  QueryDocumentSnapshot<Map<String, dynamic>>
                                >
                                rawDocs =
                                    fallbackSnapshot.data?.docs ??
                                    <
                                      QueryDocumentSnapshot<
                                        Map<String, dynamic>
                                      >
                                    >[];
                                final List<
                                  QueryDocumentSnapshot<Map<String, dynamic>>
                                >
                                docs = sortAndFilter(rawDocs);
                                if (docs.isEmpty) {
                                  return const Text('No pending requests.');
                                }
                                return Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: docs.map((
                                    QueryDocumentSnapshot<Map<String, dynamic>>
                                    doc,
                                  ) {
                                    final Map<String, dynamic> data = doc
                                        .data();
                                    final String studentName =
                                        (data['studentName'] as String?) ??
                                        'Student';
                                    final String section =
                                        (data['studentSection'] as String?) ??
                                        '';
                                    final List<dynamic> dateKeys =
                                        (data['dateKeys'] as List<dynamic>?) ??
                                        <dynamic>[];
                                    final String dateLabel = dateKeys.isEmpty
                                        ? 'No dates'
                                        : dateKeys.join(', ');
                                    final String reason =
                                        (data['reason'] as String?) ?? '';
                                    final Map<String, dynamic>? attachment =
                                        (data['attachment'] as Map?)
                                            ?.cast<String, dynamic>();

                                    return Card(
                                      margin: const EdgeInsets.symmetric(
                                        vertical: 6,
                                      ),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(16),
                                      ),
                                      child: Padding(
                                        padding: const EdgeInsets.all(12),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: <Widget>[
                                            Text(
                                              '$studentName${section.isEmpty ? '' : ' • $section'}',
                                              style: theme.textTheme.titleMedium
                                                  ?.copyWith(
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                            ),
                                            const SizedBox(height: 6),
                                            Text(
                                              dateLabel,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                            if (reason.isNotEmpty) ...<Widget>[
                                              const SizedBox(height: 6),
                                              Text(
                                                reason,
                                                maxLines: 3,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ],
                                            const SizedBox(height: 10),
                                            Wrap(
                                              spacing: 12,
                                              runSpacing: 12,
                                              children: <Widget>[
                                                OutlinedButton.icon(
                                                  onPressed: attachment == null
                                                      ? null
                                                      : () =>
                                                            _openPdfFromAttachment(
                                                              attachment,
                                                            ),
                                                  icon: const Icon(
                                                    Icons
                                                        .picture_as_pdf_outlined,
                                                  ),
                                                  label: const Text('View PDF'),
                                                ),
                                                OutlinedButton.icon(
                                                  onPressed: _isApprovingExcuse
                                                      ? null
                                                      : () =>
                                                            _disapproveExcuseRequest(
                                                              doc.id,
                                                            ),
                                                  icon: const Icon(
                                                    Icons.cancel_outlined,
                                                  ),
                                                  label: const Text(
                                                    'Disapprove',
                                                  ),
                                                ),
                                                FilledButton.icon(
                                                  onPressed: _isApprovingExcuse
                                                      ? null
                                                      : () =>
                                                            _approveExcuseRequest(
                                                              doc.id,
                                                            ),
                                                  icon: const Icon(Icons.check),
                                                  label: const Text('Approve'),
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                      ),
                                    );
                                  }).toList(),
                                );
                              },
                        );
                      }
                      return Text('Failed to load requests: ${snapshot.error}');
                    }
                    final List<QueryDocumentSnapshot<Map<String, dynamic>>>
                    docs =
                        snapshot.data?.docs ??
                        <QueryDocumentSnapshot<Map<String, dynamic>>>[];
                    if (docs.isEmpty) {
                      return const Text('No pending requests.');
                    }
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: docs.map((
                        QueryDocumentSnapshot<Map<String, dynamic>> doc,
                      ) {
                        final Map<String, dynamic> data = doc.data();
                        final String studentName =
                            (data['studentName'] as String?) ?? 'Student';
                        final String section =
                            (data['studentSection'] as String?) ?? '';
                        final List<dynamic> dateKeys =
                            (data['dateKeys'] as List<dynamic>?) ?? <dynamic>[];
                        final String dateLabel = dateKeys.isEmpty
                            ? 'No dates'
                            : dateKeys.join(', ');
                        final String reason = (data['reason'] as String?) ?? '';
                        final Map<String, dynamic>? attachment =
                            (data['attachment'] as Map?)
                                ?.cast<String, dynamic>();

                        return Card(
                          margin: const EdgeInsets.symmetric(vertical: 6),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  '$studentName${section.isEmpty ? '' : ' • $section'}',
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  dateLabel,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                if (reason.isNotEmpty) ...<Widget>[
                                  const SizedBox(height: 4),
                                  Text(
                                    reason,
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                                const SizedBox(height: 8),
                                Wrap(
                                  spacing: 12,
                                  runSpacing: 12,
                                  children: <Widget>[
                                    OutlinedButton.icon(
                                      onPressed: _isApprovingExcuse
                                          ? null
                                          : () => _disapproveExcuseRequest(
                                              doc.id,
                                            ),
                                      icon: const Icon(Icons.cancel_outlined),
                                      label: const Text('Disapprove'),
                                    ),
                                    FilledButton.icon(
                                      onPressed: _isApprovingExcuse
                                          ? null
                                          : () => _approveExcuseRequest(doc.id),
                                      icon: _isApprovingExcuse
                                          ? const SizedBox(
                                              width: 18,
                                              height: 18,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                              ),
                                            )
                                          : const Icon(
                                              Icons.check_circle_outline,
                                            ),
                                      label: const Text('Approve'),
                                    ),
                                    OutlinedButton.icon(
                                      onPressed: attachment == null
                                          ? null
                                          : () => _openPdfFromAttachment(
                                              attachment,
                                            ),
                                      icon: const Icon(
                                        Icons.picture_as_pdf_outlined,
                                      ),
                                      label: const Text('View PDF'),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        );
                      }).toList(),
                    );
                  },
            ),
          ],
        ),
      ),
    );
  }

  void _listenToApproval() {
    final User? user = FirebaseAuth.instance.currentUser;
    final String? uid = user?.uid;
    if (uid == null || uid.isEmpty) {
      setState(() {
        _approvalLoaded = true;
        _isApproved = false;
      });
      return;
    }

    _profileSubscription?.cancel();
    _profileSubscription = FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .snapshots()
        .listen(
          (DocumentSnapshot<Map<String, dynamic>> snapshot) {
            final Map<String, dynamic>? data = snapshot.data();
            final bool approved = data?['approved'] == true;
            if (!mounted) return;
            setState(() {
              _approvalLoaded = true;
              _isApproved = approved;
            });

            if (approved) {
              if (_assignmentSubscription == null) {
                _subscribeToAssignments();
              }
            } else {
              _assignmentSubscription?.cancel();
              _assignmentSubscription = null;
              if (mounted) {
                setState(() {
                  _isLoadingAssignments = false;
                  _assignmentError = null;
                  _assignments = <_InstructorClassAssignment>[];
                  _scheduleEntries = <_InstructorSchedule>[];
                });
              }
            }
          },
          onError: (Object error) {
            if (!mounted) return;
            setState(() {
              _approvalLoaded = true;
              _isApproved = false;
            });
          },
        );
  }

  Future<void> _handleSignOut() async {
    final bool shouldSignOut = await showConfirmSignOutDialog(context);
    if (!shouldSignOut) return;
    if (!mounted) return;

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
    Navigator.of(
      context,
    ).pushNamedAndRemoveUntil('/login', (Route<dynamic> route) => false);
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
        _assignmentError =
            'You must be signed in to view your assigned classes.';
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
            final List<_InstructorSchedule> scheduleEntries =
                assignments
                    .expand(
                      (_InstructorClassAssignment assignment) =>
                          assignment.schedules,
                    )
                    .toList()
                  ..sort(_InstructorSchedule.compareByDayAndTime);
            setState(() {
              _assignments = assignments;
              _scheduleEntries = scheduleEntries;
              _isLoadingAssignments = false;
              _assignmentError = null;
            });

            _refreshOfflineModeStatus();
          },
          onError: (Object error, StackTrace stackTrace) {
            setState(() {
              _assignmentError = 'Failed to load classes. $error';
              _isLoadingAssignments = false;
              _assignments = <_InstructorClassAssignment>[];
              _scheduleEntries = <_InstructorSchedule>[];
            });

            _refreshOfflineModeStatus();
          },
        );
  }

  List<String> _sectionLabelsForAssignments() {
    return _assignments
        .map((a) => a.section?.trim() ?? '')
        .where((s) => s.isNotEmpty)
        .toSet()
        .toList(growable: false);
  }

  Future<void> _refreshOfflineModeStatus() async {
    if (!mounted) return;

    final List<String> sectionLabels = _sectionLabelsForAssignments();
    final int requestId = ++_offlineModeRequestId;
    setState(() => _offlineModeChecking = true);

    try {
      final OfflineModeStatus status = await _offlineModeService
          .getStatusForSections(sectionLabels);
      if (!mounted || requestId != _offlineModeRequestId) return;
      setState(() {
        _offlineModeStatus = status;
        _offlineModeChecking = false;
      });
    } catch (_) {
      if (!mounted || requestId != _offlineModeRequestId) return;
      setState(() {
        _offlineModeStatus = null;
        _offlineModeChecking = false;
      });
    }
  }

  Future<void> _openOfflineModeChecklist() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => OfflineModeChecklistPage(
          sectionLabels: _sectionLabelsForAssignments(),
        ),
      ),
    );
    await _refreshOfflineModeStatus();
  }

  Color _offlineModeColor(ThemeData theme) {
    if (_offlineModeChecking) return theme.colorScheme.outline;
    final bool ready = _offlineModeStatus?.isReady == true;
    return ready ? const Color(0xFF0B6B2C) : const Color(0xFF7A0C2E);
  }

  String _offlineModeLabel() {
    if (_offlineModeChecking) return 'Checking';
    if (_offlineModeStatus == null) return 'Unknown';
    return _offlineModeStatus!.isReady ? 'Ready' : 'Not ready';
  }

  Widget _buildOfflineBadge(ThemeData theme, {double size = 12}) {
    final Color color = _offlineModeColor(theme);
    if (_offlineModeChecking) {
      return SizedBox(
        width: size,
        height: size,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          valueColor: AlwaysStoppedAnimation<Color>(color),
        ),
      );
    }
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: theme.colorScheme.surface, width: 2),
      ),
    );
  }

  Widget _buildOfflineModeDrawerTile(ThemeData theme) {
    final String label = _offlineModeLabel();
    final Color color = _offlineModeColor(theme);

    return ListTile(
      leading: const Icon(Icons.cloud_off_outlined),
      title: const Text('Offline mode'),
      subtitle: Text(
        label,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.outline,
        ),
      ),
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: color.withValues(alpha: 0.45)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _buildOfflineBadge(theme, size: 10),
            const SizedBox(width: 8),
            Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                color: color,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
      onTap: _openOfflineModeChecklist,
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

  Future<void> _startRecognitionSession(
    _InstructorSchedule schedule, {
    String? resumeSessionId,
  }) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final NavigatorState navigator = Navigator.of(context);

    final DateTime effectiveNow = _simulationEnabled
        ? _simulatedTime
        : DateTime.now();
    final AttendanceCalendarDay? override = await _calendar.fetchDayBestEffort(
      day: effectiveNow,
    );
    if (override != null) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Attendance disabled today: ${override.label} (${override.code}).',
          ),
        ),
      );
      return;
    }
    if (!isAndroidFaceScanningSupported()) {
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Face scanning is available only in the Android app.'),
        ),
      );
      return;
    }
    if (_isLaunchingSession) return;
    setState(() => _isLaunchingSession = true);
    final DateTime launchNow = DateTime.now();
    final Duration? simulatedClockOffset = _simulationEnabled
        ? _simulatedTime.difference(launchNow)
        : null;

    try {
      String? effectiveResumeSessionId = resumeSessionId;
      final String? pointerId = _pointerIdForSchedule(
        schedule: schedule,
        activeTime: effectiveNow,
      );

      if (pointerId != null) {
        DocumentSnapshot<Map<String, dynamic>>? pointerSnap;
        try {
          pointerSnap = await FirebaseFirestore.instance
              .collection(_kSessionPointerCollection)
              .doc(pointerId)
              .get(const GetOptions(source: Source.server))
              .timeout(const Duration(seconds: 3));
        } catch (_) {
          try {
            pointerSnap = await FirebaseFirestore.instance
                .collection(_kSessionPointerCollection)
                .doc(pointerId)
                .get(const GetOptions(source: Source.cache))
                .timeout(const Duration(seconds: 2));
          } catch (_) {
            pointerSnap = null;
          }
        }

        final Map<String, dynamic>? data = pointerSnap?.data();
        final String status = (data?['status'] as String?)?.toLowerCase() ?? '';
        final String sessionId = (data?['sessionId'] as String?)?.trim() ?? '';
        final String pointerScheduleKey =
            (data?['scheduleKey'] as String?)?.trim() ?? '';
        final Timestamp? scheduledEndTs = data?['scheduledEndAt'] as Timestamp?;
        final DateTime? scheduledEnd = scheduledEndTs?.toDate();

        final String desiredScheduleKey = _scheduleKeyFor(
          dayOfWeek: schedule.dayOfWeek,
          start: schedule.start,
          end: schedule.end,
        );
        final bool pointerMatchesSchedule =
            pointerScheduleKey.isEmpty ||
            pointerScheduleKey == desiredScheduleKey;

        final bool expired =
            scheduledEnd != null &&
            (effectiveNow.isAfter(scheduledEnd) ||
                effectiveNow.isAtSameMomentAs(scheduledEnd));
        final bool resumable =
            sessionId.isNotEmpty &&
            (status == 'active' || status == 'paused') &&
          !expired &&
          pointerMatchesSchedule;

        if (expired &&
            sessionId.isNotEmpty &&
            status.isNotEmpty &&
            status != 'completed') {
          await _completeExpiredSessionBestEffort(
            sessionId: sessionId,
            pointerId: pointerId,
          );
          if (!mounted) return;
          messenger.showSnackBar(
            const SnackBar(
              content: Text('Previous session ended automatically.'),
            ),
          );
          return;
        }

        if (resumable) {
          effectiveResumeSessionId = sessionId;
        }
      }

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
        simulatedClockOffset: simulatedClockOffset,
        resumeSessionId: effectiveResumeSessionId,
      );

      final bool? completed = await navigator.push<bool?>(
        MaterialPageRoute<bool?>(
          builder: (BuildContext context) =>
              AttendanceSessionPage(config: config),
          settings: RouteSettings(
            name: AttendanceSessionPage.routeName,
            arguments: config,
          ),
        ),
      );
      if (!mounted) return;
      if (completed == true) {
        messenger.showSnackBar(
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
    final int sessionsToday = _scheduleEntries
        .where(
          (_InstructorSchedule entry) => entry.dayOfWeek == activeTime.weekday,
        )
        .length;
    final int assignedSections = _assignments.length;
    final int weeklySessions = _scheduleEntries.length;

    return <_InstructorStat>[
      _InstructorStat(
        label: 'Classes Today',
        value: _formatCounter(sessionsToday),
        icon: Icons.event_note_outlined,
      ),
      _InstructorStat(
        label: 'Assigned Sections',
        value: _formatCounter(assignedSections),
        icon: Icons.layers_outlined,
      ),
      _InstructorStat(
        label: 'Weekly Sessions',
        value: _formatCounter(weeklySessions),
        icon: Icons.schedule_outlined,
      ),
    ];
  }

  String _formatCounter(int value) => value.toString().padLeft(2, '0');

  @override
  Widget build(BuildContext context) {
    if (!_approvalLoaded) {
      return const Scaffold(
        body: SafeArea(child: Center(child: CircularProgressIndicator())),
      );
    }

    if (!_isApproved) {
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
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(Icons.verified_user_outlined, size: 42),
                    SizedBox(height: 12),
                    Text(
                      'Your instructor account is pending approval.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    SizedBox(height: 8),
                    Text(
                      'Please wait for the admin to approve your account. You will be able to access instructor features once approved.',
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    final ThemeData theme = Theme.of(context);
    final DateTime liveTime = DateTime.now();
    final DateTime sessionTime = _activeTime;
    final _InstructorSchedule? activeSchedule = _resolveActiveSchedule(
      sessionTime,
    );
    final _InstructorSchedule? nextSchedule = _resolveNextSchedule(sessionTime);
    final _InstructorSchedule? nextScheduleLive = _resolveNextSchedule(
      liveTime,
    );
    final List<_InstructorStat> stats = _buildInstructorStats(liveTime);
    final bool showLoadingState = _isLoadingAssignments && _assignments.isEmpty;
    final bool hasAssignments = _assignments.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        leading: Builder(
          builder: (BuildContext context) {
            return IconButton(
              tooltip: 'Menu',
              onPressed: () => Scaffold.of(context).openDrawer(),
              icon: Stack(
                clipBehavior: Clip.none,
                children: <Widget>[
                  const Icon(Icons.menu),
                  if (_offlineModeChecking ||
                      _offlineModeStatus?.isReady != true)
                    Positioned(
                      top: -2,
                      right: -2,
                      child: _buildOfflineBadge(theme, size: 12),
                    ),
                ],
              ),
            );
          },
        ),
        title: Row(
          children: <Widget>[
            Icon(_sectionIcon(), size: 20),
            const SizedBox(width: 10),
            Text(_sectionTitle()),
          ],
        ),
        actions: <Widget>[
          Builder(
            builder: (BuildContext context) {
              final User? user = FirebaseAuth.instance.currentUser;
              final String? uid = user?.uid;
              if (uid == null || uid.isEmpty) {
                return const SizedBox.shrink();
              }
              return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: FirebaseFirestore.instance
                    .collection('users')
                    .doc(uid)
                    .collection('notifications')
                    .where('readAt', isNull: true)
                    .limit(1)
                    .snapshots(),
                builder:
                    (
                      BuildContext context,
                      AsyncSnapshot<QuerySnapshot<Map<String, dynamic>>>
                      snapshot,
                    ) {
                      final bool hasUnread =
                          snapshot.hasData && snapshot.data!.docs.isNotEmpty;
                      return IconButton(
                        tooltip: 'Notifications',
                        onPressed: () {
                          Navigator.of(
                            context,
                          ).pushNamed(NotificationsPage.routeName);
                        },
                        icon: Stack(
                          clipBehavior: Clip.none,
                          children: <Widget>[
                            const Icon(Icons.notifications_outlined),
                            if (hasUnread)
                              Positioned(
                                top: -1,
                                right: -1,
                                child: Icon(
                                  Icons.circle,
                                  size: 10,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                              ),
                          ],
                        ),
                      );
                    },
              );
            },
          ),
        ],
      ),
      drawer: Drawer(
        child: SafeArea(
          child: Column(
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 18, 16, 12),
                child: Row(
                  children: <Widget>[
                    CircleAvatar(
                      backgroundColor: theme.colorScheme.primaryContainer,
                      child: Icon(
                        Icons.school_outlined,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            FirebaseAuth.instance.currentUser?.displayName
                                        ?.trim()
                                        .isNotEmpty ==
                                    true
                                ? FirebaseAuth
                                      .instance
                                      .currentUser!
                                      .displayName!
                                : 'Instructor',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            FirebaseAuth.instance.currentUser?.email ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.outline,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.dashboard_outlined),
                title: const Text('Dashboard'),
                selected: _section == _InstructorSection.dashboard,
                onTap: () => _selectSection(_InstructorSection.dashboard),
              ),
              ListTile(
                leading: const Icon(Icons.play_circle_outline),
                title: const Text('Attendance session'),
                selected: _section == _InstructorSection.attendanceSession,
                onTap: () =>
                    _selectSection(_InstructorSection.attendanceSession),
              ),
              ListTile(
                leading: const Icon(Icons.insights_outlined),
                title: const Text('Attendance reports'),
                selected: _section == _InstructorSection.attendanceReports,
                onTap: () =>
                    _selectSection(_InstructorSection.attendanceReports),
              ),
              ListTile(
                leading: const Icon(Icons.calendar_month_outlined),
                title: const Text('Weekly schedule'),
                selected: _section == _InstructorSection.weeklySchedule,
                onTap: () => _selectSection(_InstructorSection.weeklySchedule),
              ),
              const Divider(height: 1),
              _buildOfflineModeDrawerTile(theme),
              const Spacer(),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.logout),
                title: const Text('Sign out'),
                onTap: () {
                  Navigator.of(context).maybePop();
                  Future<void>.microtask(_handleSignOut);
                },
              ),
            ],
          ),
        ),
      ),
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          child: switch (_section) {
            _InstructorSection.dashboard => _buildDashboardTab(
              theme,
              stats,
              showLoadingState,
            ),
            _InstructorSection.attendanceSession => _buildAttendanceSessionTab(
              sessionTime,
              nextSchedule,
              activeSchedule,
              showLoadingState,
              hasAssignments,
            ),
            _InstructorSection.attendanceReports => _buildAttendanceReportsTab(
              hasAssignments,
            ),
            _InstructorSection.weeklySchedule => _buildWeeklyScheduleTab(
              liveTime,
              nextScheduleLive,
              showLoadingState,
              hasAssignments,
            ),
          },
        ),
      ),
    );
  }

  Widget _buildSimulationPanel(BuildContext context, DateTime activeTime) {
    final ThemeData theme = Theme.of(context);
    final MaterialLocalizations localizations = MaterialLocalizations.of(
      context,
    );
    final String timeLabel = localizations.formatTimeOfDay(
      TimeOfDay.fromDateTime(activeTime),
    );
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
                        style: theme.textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(dateLabel, style: theme.textTheme.bodyMedium),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: <Widget>[
                    Text('Simulation mode', style: theme.textTheme.labelLarge),
                    Switch.adaptive(
                      value: _simulationEnabled,
                      onChanged: _toggleSimulation,
                    ),
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
                  onPressed: _simulationEnabled
                      ? () => _adjustSimulatedTime(const Duration(minutes: -15))
                      : null,
                  icon: const Icon(Icons.history_toggle_off),
                  label: const Text('- 15 min'),
                ),
                OutlinedButton.icon(
                  onPressed: _simulationEnabled
                      ? () => _adjustSimulatedTime(const Duration(minutes: 15))
                      : null,
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
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            if (showLoadingIndicator)
              const SizedBox(
                height: 18,
                width: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
        const SizedBox(height: 16),
        if (stats.isEmpty)
          Card(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            child: const Padding(
              padding: EdgeInsets.all(20),
              child: Text(
                'No classes assigned yet. Coordinate with the admin team to get started.',
              ),
            ),
          )
        else
          Wrap(
            spacing: 16,
            runSpacing: 16,
            children: stats
                .map((_InstructorStat stat) => _InstructorStatCard(stat: stat))
                .toList(),
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
            Text(
              '${_formatScheduleRange(context, nextSchedule)} • ${nextSchedule.location ?? 'Location TBD'}',
            ),
            const SizedBox(height: 6),
            Text(
              countdownLabel,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSessionControlCard(
    BuildContext context,
    DateTime activeTime,
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
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
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
              Builder(
                builder: (BuildContext context) {
                  final String? pointerId = _pointerIdForSchedule(
                    schedule: activeSchedule,
                    activeTime: activeTime,
                  );
                  if (pointerId == null) {
                    return FilledButton.icon(
                      onPressed: _isLaunchingSession
                          ? null
                          : () => _startRecognitionSession(activeSchedule),
                      icon: _isLaunchingSession
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.play_arrow_rounded),
                      label: Text(
                        _isLaunchingSession
                            ? 'Launching...'
                            : 'Start recognition session',
                      ),
                    );
                  }

                  return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                    stream: FirebaseFirestore.instance
                        .collection(_kSessionPointerCollection)
                        .doc(pointerId)
                        .snapshots(),
                    builder:
                        (
                          BuildContext context,
                          AsyncSnapshot<DocumentSnapshot<Map<String, dynamic>>>
                          snapshot,
                        ) {
                          final Map<String, dynamic>? data = snapshot.data
                              ?.data();
                          final String status =
                              (data?['status'] as String?)?.toLowerCase() ?? '';
                          final String sessionId =
                              (data?['sessionId'] as String?)?.trim() ?? '';
                            final String pointerScheduleKey =
                              (data?['scheduleKey'] as String?)?.trim() ?? '';
                          final Timestamp? scheduledEndTs =
                              data?['scheduledEndAt'] as Timestamp?;
                          final DateTime? scheduledEnd = scheduledEndTs
                              ?.toDate();

                            final String desiredScheduleKey = _scheduleKeyFor(
                            dayOfWeek: activeSchedule.dayOfWeek,
                            start: activeSchedule.start,
                            end: activeSchedule.end,
                            );
                            final bool pointerMatchesSchedule =
                              pointerScheduleKey.isEmpty ||
                              pointerScheduleKey == desiredScheduleKey;

                          final bool expired =
                              scheduledEnd != null &&
                              (activeTime.isAfter(scheduledEnd) ||
                                  activeTime.isAtSameMomentAs(scheduledEnd));
                          final bool resumable =
                              sessionId.isNotEmpty &&
                              (status == 'active' || status == 'paused') &&
                              !expired &&
                              pointerMatchesSchedule;

                            final bool reopenable =
                              sessionId.isNotEmpty &&
                              status == 'completed' &&
                              pointerMatchesSchedule;

                          if (expired &&
                              sessionId.isNotEmpty &&
                              status.isNotEmpty &&
                              status != 'completed') {
                            Future<void>.microtask(() async {
                              await _completeExpiredSessionBestEffort(
                                sessionId: sessionId,
                                pointerId: pointerId,
                              );
                            });
                          }

                          final String buttonLabel = _isLaunchingSession
                              ? 'Launching...'
                            : (resumable
                              ? 'Continue Session'
                              : (reopenable
                                ? 'Reopen session'
                                : 'Start recognition session'));

                          return FilledButton.icon(
                            onPressed: _isLaunchingSession
                                ? null
                                : () async {
                                    if (reopenable) {
                                      final bool confirmed =
                                          await _confirmReopenCompletedSession(
                                            context,
                                            expired: expired,
                                          );
                                      if (!confirmed || !mounted) return;

                                      setState(() => _isLaunchingSession = true);
                                      final bool reopened =
                                          await _reopenSessionBestEffort(
                                            sessionId: sessionId,
                                            pointerId: pointerId,
                                          );
                                      if (!mounted) return;
                                      setState(() => _isLaunchingSession = false);

                                      if (!reopened) {
                                        ScaffoldMessenger.of(this.context)
                                            .showSnackBar(
                                          const SnackBar(
                                            content: Text(
                                              'Failed to reopen session. Check your connection and try again.',
                                            ),
                                          ),
                                        );
                                        return;
                                      }

                                      await _startRecognitionSession(
                                        activeSchedule,
                                        resumeSessionId: sessionId,
                                      );
                                      return;
                                    }

                                    await _startRecognitionSession(
                                      activeSchedule,
                                      resumeSessionId: resumable ? sessionId : null,
                                    );
                                  },
                            icon: _isLaunchingSession
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : Icon(
                                    resumable
                                        ? Icons.play_circle_outline
                                        : (reopenable
                                              ? Icons.replay_circle_filled_outlined
                                              : Icons.play_arrow_rounded),
                                  ),
                            label: Text(buttonLabel),
                          );
                        },
                  );
                },
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

  Widget _buildReportShortcutCard(BuildContext context, bool hasAssignments) {
    final ThemeData theme = Theme.of(context);
    final String helperText = hasAssignments
        ? 'Generate printable attendance logs for your assigned sections.'
        : 'You need at least one assigned class before generating reports.';
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Attendance reports',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(helperText, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: hasAssignments
                  ? () => Navigator.of(
                      context,
                    ).pushNamed(GenerateReportPage.routeName)
                  : null,
              icon: const Icon(Icons.insights_outlined),
              label: const Text('Generate report'),
            ),
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
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
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
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
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
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
                margin: const EdgeInsets.symmetric(vertical: 8),
                child: ListTile(
                  leading: Icon(
                    isActive ? Icons.play_circle_fill : Icons.class_outlined,
                    color: isActive
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                  title: Text(
                    '${schedule.subjectCode} • ${schedule.subjectName}',
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(_formatSectionLabel(schedule)),
                      const SizedBox(height: 2),
                      Text(
                        '${_formatScheduleRange(context, schedule)} • ${schedule.location ?? 'Location TBD'}',
                      ),
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
                          backgroundColor:
                              theme.colorScheme.surfaceContainerHigh,
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
            if (child != null) ...<Widget>[const SizedBox(height: 12), child],
          ],
        ),
      ),
    );
  }

  String _formatSectionLabel(_InstructorSchedule schedule) {
    final String sectionLabel = schedule.section == null
        ? 'Section TBD'
        : 'Section ${schedule.section}';
    final String termLabel = schedule.term == null ? '' : ' • ${schedule.term}';
    return '$sectionLabel$termLabel';
  }

  String _formatScheduleRange(
    BuildContext context,
    _InstructorSchedule schedule,
  ) {
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
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
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
  const _InstructorStat({
    required this.label,
    required this.value,
    required this.icon,
  });

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
    final String subjectName =
        (data['subjectName'] as String?) ?? 'Untitled Subject';
    final String? section = (data['section'] as String?)?.trim();
    final String? term = (data['term'] as String?)?.trim();
    final String? departmentName = (data['departmentName'] as String?)?.trim();
    final List<dynamic> rawSchedules =
        data['schedules'] as List<dynamic>? ?? <dynamic>[];

    final List<_InstructorSchedule> schedules = rawSchedules
        .map(
          (dynamic item) => _InstructorSchedule.fromMap(
            classId: doc.id,
            data: item as Map<String, dynamic>?,
            subjectCode: subjectCode,
            subjectName: subjectName,
            section: section,
            term: term,
            departmentName: departmentName,
          ),
        )
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
    final TimeOfDay? startTime = _timeFromMap(
      data['startTime'] as Map<String, dynamic>?,
    );
    final TimeOfDay? endTime = _timeFromMap(
      data['endTime'] as Map<String, dynamic>?,
    );
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
    final DateTime base = DateTime(
      reference.year,
      reference.month,
      reference.day,
    ).add(Duration(days: weekdayDelta));
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
