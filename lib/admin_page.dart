import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'widgets/confirm_sign_out_dialog.dart';
import 'package:printing/printing.dart';

import 'reports/generate_report_page.dart';
import 'reports/attendance_report_template_meta.dart';
import 'reports/instructor_sessions_report_page.dart';
import 'services/excuse_request_service.dart';
import 'services/open_external_url.dart';
import 'services/user_role_service.dart';
import 'services/vps_embeddings_api_client.dart';

enum _AdminSection {
  overview,
  users,
  departments,
  subjects,
  classes,
  attendanceSessions,
  excuses,
}

class AdminPage extends StatefulWidget {
  const AdminPage({super.key});

  static const String routeName = '/admin';

  @override
  State<AdminPage> createState() => _AdminPageState();
}

class _AdminPageState extends State<AdminPage> {
  _AdminSection _selectedSection = _AdminSection.overview;
  late Future<_AdminOverviewStats> _overviewFuture;
  final ExcuseRequestService _excuseService = ExcuseRequestService();
  bool _isApprovingExcuse = false;
  bool _isDeletingExcuse = false;
  static const List<_SectionNavItem> _navItems = <_SectionNavItem>[
    _SectionNavItem(
      _AdminSection.overview,
      'System Overview',
      Icons.space_dashboard_outlined,
    ),
    _SectionNavItem(
      _AdminSection.users,
      'User Management',
      Icons.people_outline,
    ),
    _SectionNavItem(
      _AdminSection.departments,
      'Department Maintenance',
      Icons.account_tree_outlined,
    ),
    _SectionNavItem(
      _AdminSection.subjects,
      'Subject Catalog',
      Icons.menu_book_outlined,
    ),
    _SectionNavItem(
      _AdminSection.classes,
      'Class Maintenance',
      Icons.class_outlined,
    ),
    _SectionNavItem(
      _AdminSection.attendanceSessions,
      'Attendance Sessions',
      Icons.event_note_outlined,
    ),
    _SectionNavItem(
      _AdminSection.excuses,
      'Excuse Requests',
      Icons.report_problem_outlined,
    ),
  ];

  String _labelForSection(_AdminSection section) {
    for (final _SectionNavItem item in _navItems) {
      if (item.section == section) return item.label;
    }
    return section.name;
  }

  IconData _iconForSection(_AdminSection section) {
    for (final _SectionNavItem item in _navItems) {
      if (item.section == section) return item.icon;
    }
    return Icons.dashboard_outlined;
  }

  Future<void> _handleSignOut() async {
    final bool shouldSignOut = await showConfirmSignOutDialog(context);
    if (!mounted) return;
    if (!shouldSignOut) return;

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

  Widget _buildAdminDrawer() {
    return Drawer(
      child: SafeArea(
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(
                children: <Widget>[
                  const Expanded(
                    child: Text(
                      'Admin Modules',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: <Widget>[
                  for (final _SectionNavItem item in _navItems)
                    ListTile(
                      leading: Icon(item.icon),
                      title: Text(item.label),
                      selected: item.section == _selectedSection,
                      onTap: () {
                        setState(() => _selectedSection = item.section);
                        Navigator.of(context).pop();
                      },
                    ),
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text(
                      'Admin Actions',
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.description_outlined),
                    title: const Text('Edit Report Header Details'),
                    onTap: () async {
                      Navigator.of(context).pop();
                      await showDialog<void>(
                        context: context,
                        builder: (BuildContext context) =>
                            const _AttendanceReportTemplateMetaDialog(),
                      );
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.insights_outlined),
                    title: const Text('Generate Attendance Reports'),
                    onTap: () {
                      Navigator.of(context).pop();
                      Navigator.of(
                        context,
                      ).pushNamed(GenerateReportPage.routeName);
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.fact_check_outlined),
                    title: const Text('Instructor Sessions Report'),
                    onTap: () {
                      Navigator.of(context).pop();
                      Navigator.of(
                        context,
                      ).pushNamed(InstructorSessionsReportPage.routeName);
                    },
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.logout),
                    title: const Text('Sign out'),
                    onTap: () async {
                      Navigator.of(context).pop();
                      await _handleSignOut();
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
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

  Future<void> _approveExcuseRequest(String requestId) async {
    if (_isApprovingExcuse) return;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Approve excuse request?'),
        content: const Text(
          'This will immediately mark the absence as excused.',
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
        content: const Text('This will mark the request as rejected.'),
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
      ).showSnackBar(SnackBar(content: Text('Rejection failed: $error')));
    } finally {
      if (mounted) setState(() => _isApprovingExcuse = false);
    }
  }

  Future<void> _deleteExcuseRequest(String requestId) async {
    if (_isDeletingExcuse) return;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Delete excuse request?'),
        content: const Text(
          'Only admins can delete requests. This cannot be undone.',
        ),
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
    if (confirmed != true) return;
    setState(() => _isDeletingExcuse = true);
    try {
      await _excuseService.delete(requestId: requestId);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Excuse request deleted.')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Delete failed: $error')));
    } finally {
      if (mounted) setState(() => _isDeletingExcuse = false);
    }
  }

  Widget _buildExcuseRequestsPanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text('Approve or delete student excuse requests.'),
                const SizedBox(height: 16),
                StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  stream: FirebaseFirestore.instance
                      .collection('excuseRequests')
                      .orderBy('createdAt', descending: true)
                      .limit(50)
                      .snapshots(),
                  builder:
                      (
                        BuildContext context,
                        AsyncSnapshot<QuerySnapshot<Map<String, dynamic>>>
                        snapshot,
                      ) {
                        if (snapshot.connectionState ==
                            ConnectionState.waiting) {
                          return const Center(
                            child: Padding(
                              padding: EdgeInsets.symmetric(vertical: 12),
                              child: CircularProgressIndicator(),
                            ),
                          );
                        }
                        if (snapshot.hasError) {
                          return Text(
                            'Failed to load requests: ${snapshot.error}',
                          );
                        }
                        final List<QueryDocumentSnapshot<Map<String, dynamic>>>
                        docs =
                            snapshot.data?.docs ??
                            <QueryDocumentSnapshot<Map<String, dynamic>>>[];
                        if (docs.isEmpty) {
                          return const Text('No requests found.');
                        }
                        return ListView.separated(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: docs.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (BuildContext context, int index) {
                            final QueryDocumentSnapshot<Map<String, dynamic>>
                            doc = docs[index];
                            final Map<String, dynamic> data = doc.data();
                            final String status =
                                (data['status'] as String?) ?? 'pending';
                            final bool isPending =
                                status.toLowerCase() == 'pending';
                            final String studentName =
                                (data['studentName'] as String?) ?? 'Student';
                            final String section =
                                (data['studentSection'] as String?) ?? '';
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

                            final String titleText =
                                '$studentName${section.isEmpty ? '' : ' • $section'}';
                            final String statusLabel = status.toUpperCase();
                            final bool canReview =
                                isPending && !_isApprovingExcuse;
                            final bool canDelete = !_isDeletingExcuse;
                            final bool isBusy =
                                (_isApprovingExcuse && isPending) ||
                                _isDeletingExcuse;

                            return ListTile(
                              contentPadding: EdgeInsets.zero,
                              isThreeLine: reason.isNotEmpty,
                              title: Text(
                                titleText,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(
                                    dateLabel,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  if (reason.isNotEmpty)
                                    Text(
                                      reason,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                ],
                              ),
                              trailing: SizedBox(
                                width: 190,
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  mainAxisSize: MainAxisSize.min,
                                  children: <Widget>[
                                    Flexible(
                                      child: ConstrainedBox(
                                        constraints: const BoxConstraints(
                                          maxWidth: 140,
                                        ),
                                        child: Chip(
                                          visualDensity: VisualDensity.compact,
                                          label: Text(
                                            statusLabel,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    if (isBusy)
                                      const SizedBox(
                                        width: 24,
                                        height: 24,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    else ...<Widget>[
                                      IconButton(
                                        tooltip: 'Delete',
                                        onPressed: canDelete
                                            ? () => _deleteExcuseRequest(doc.id)
                                            : null,
                                        constraints: const BoxConstraints(
                                          minWidth: 36,
                                          minHeight: 36,
                                        ),
                                        padding: EdgeInsets.zero,
                                        icon: const Icon(
                                          Icons.delete_outline,
                                          size: 20,
                                        ),
                                      ),
                                      PopupMenuButton<String>(
                                        tooltip: 'Actions',
                                        onSelected: (String action) {
                                          switch (action) {
                                            case 'pdf':
                                              if (attachment != null) {
                                                _openPdfFromAttachment(
                                                  attachment,
                                                );
                                              }
                                              break;
                                            case 'approve':
                                              _approveExcuseRequest(doc.id);
                                              break;
                                            case 'disapprove':
                                              _disapproveExcuseRequest(doc.id);
                                              break;
                                            case 'delete':
                                              _deleteExcuseRequest(doc.id);
                                              break;
                                          }
                                        },
                                        itemBuilder: (BuildContext context) {
                                          return <PopupMenuEntry<String>>[
                                            PopupMenuItem<String>(
                                              value: 'pdf',
                                              enabled: attachment != null,
                                              child: const Row(
                                                children: <Widget>[
                                                  Icon(
                                                    Icons
                                                        .picture_as_pdf_outlined,
                                                    size: 18,
                                                  ),
                                                  SizedBox(width: 10),
                                                  Text('Open PDF'),
                                                ],
                                              ),
                                            ),
                                            PopupMenuItem<String>(
                                              value: 'approve',
                                              enabled: canReview,
                                              child: const Row(
                                                children: <Widget>[
                                                  Icon(
                                                    Icons.check_circle_outline,
                                                    size: 18,
                                                  ),
                                                  SizedBox(width: 10),
                                                  Text('Approve'),
                                                ],
                                              ),
                                            ),
                                            PopupMenuItem<String>(
                                              value: 'disapprove',
                                              enabled: canReview,
                                              child: const Row(
                                                children: <Widget>[
                                                  Icon(
                                                    Icons.cancel_outlined,
                                                    size: 18,
                                                  ),
                                                  SizedBox(width: 10),
                                                  Text('Disapprove'),
                                                ],
                                              ),
                                            ),
                                            const PopupMenuDivider(),
                                            PopupMenuItem<String>(
                                              value: 'delete',
                                              enabled: canDelete,
                                              child: const Row(
                                                children: <Widget>[
                                                  Icon(
                                                    Icons.delete_outline,
                                                    size: 18,
                                                  ),
                                                  SizedBox(width: 10),
                                                  Text('Delete'),
                                                ],
                                              ),
                                            ),
                                          ];
                                        },
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            );
                          },
                        );
                      },
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  @override
  void initState() {
    super.initState();
    _overviewFuture = _loadOverviewStats();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Scaffold(
      drawer: _buildAdminDrawer(),
      appBar: AppBar(
        title: const Text('Admin Dashboard'),
        leading: Builder(
          builder: (BuildContext context) {
            return IconButton(
              tooltip: 'Menu',
              icon: const Icon(Icons.menu),
              onPressed: () => Scaffold.of(context).openDrawer(),
            );
          },
        ),
        actions: <Widget>[],
      ),
      body: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final bool isWide = constraints.maxWidth >= 900;
          final EdgeInsets padding = EdgeInsets.symmetric(
            horizontal: isWide ? 48 : 24,
            vertical: 32,
          );
          return SingleChildScrollView(
            padding: padding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Icon(_iconForSection(_selectedSection), size: 22),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _labelForSection(_selectedSection),
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  switchInCurve: Curves.easeInOut,
                  switchOutCurve: Curves.easeInOut,
                  child: KeyedSubtree(
                    key: ValueKey<_AdminSection>(_selectedSection),
                    child: _buildSectionContent(
                      section: _selectedSection,
                      theme: theme,
                      isWide: isWide,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildSectionContent({
    required _AdminSection section,
    required ThemeData theme,
    required bool isWide,
  }) {
    switch (section) {
      case _AdminSection.overview:
        return FutureBuilder<_AdminOverviewStats>(
          future: _overviewFuture,
          builder:
              (
                BuildContext context,
                AsyncSnapshot<_AdminOverviewStats> snapshot,
              ) {
                Widget statsContent;
                _AdminOverviewStats? resolved;
                if (snapshot.connectionState == ConnectionState.waiting) {
                  statsContent = Wrap(
                    spacing: 16,
                    runSpacing: 16,
                    children: List<Widget>.generate(
                      3,
                      (int index) => _AdminStatPlaceholder(isWide: isWide),
                    ),
                  );
                } else if (snapshot.hasError) {
                  statsContent = Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          const Text('Unable to load overview stats.'),
                          const SizedBox(height: 8),
                          Text(
                            snapshot.error.toString(),
                            style: theme.textTheme.bodySmall,
                          ),
                          const SizedBox(height: 12),
                          TextButton.icon(
                            onPressed: _refreshOverviewStats,
                            icon: const Icon(Icons.refresh),
                            label: const Text('Retry'),
                          ),
                        ],
                      ),
                    ),
                  );
                } else {
                  resolved = snapshot.data ?? const _AdminOverviewStats();
                  final _AdminOverviewStats data = resolved;
                  final List<_AdminStat> stats = <_AdminStat>[
                    _AdminStat(
                      label: 'Instructors',
                      value: data.instructors.toString(),
                      icon: Icons.school_outlined,
                    ),
                    _AdminStat(
                      label: 'Students',
                      value: data.students.toString(),
                      icon: Icons.people_outline,
                    ),
                    _AdminStat(
                      label: 'Alerts',
                      value: data.alerts.toString(),
                      icon: Icons.warning_amber_rounded,
                    ),
                  ];
                  statsContent = Wrap(
                    spacing: 16,
                    runSpacing: 16,
                    children: stats
                        .map(
                          (_AdminStat stat) =>
                              _AdminStatCard(stat: stat, isWide: isWide),
                        )
                        .toList(),
                  );
                }

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const SizedBox(height: 8),
                    statsContent,
                    if (resolved != null) ...<Widget>[
                      const SizedBox(height: 16),
                      _EnrollmentCombinedChartCard(
                        studentsTotal: resolved.students,
                        instructorsTotal: resolved.instructors,
                        studentsBySection: resolved.studentsBySection,
                        instructorsByDepartment:
                            resolved.instructorsByDepartment,
                      ),
                    ],
                  ],
                );
              },
        );
      case _AdminSection.departments:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const <Widget>[_DepartmentMaintenancePanel()],
        );
      case _AdminSection.users:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const <Widget>[_UserManagementPanel()],
        );
      case _AdminSection.subjects:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const <Widget>[_SubjectCatalogPanel()],
        );
      case _AdminSection.classes:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const <Widget>[_ClassMaintenancePanel()],
        );
      case _AdminSection.attendanceSessions:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const <Widget>[_AttendanceSessionsPanel()],
        );
      case _AdminSection.excuses:
        return _buildExcuseRequestsPanel();
    }
  }

  Future<_AdminOverviewStats> _loadOverviewStats() async {
    final FirebaseFirestore firestore = FirebaseFirestore.instance;
    final Query<Map<String, dynamic>> usersCollection = firestore.collection(
      'users',
    );

    String resolveField(Map<String, dynamic> data, List<String> candidates) {
      for (final String key in candidates) {
        final Object? value = data[key];
        if (value is String && value.trim().isNotEmpty) {
          return value.trim();
        }
      }
      return '';
    }

    String normalizeBucket(String raw, {required String emptyLabel}) {
      final String v = raw.trim();
      return v.isEmpty ? emptyLabel : v;
    }

    final Future<QuerySnapshot<Map<String, dynamic>>> instructorsSnapFuture =
        usersCollection.where('role', isEqualTo: 'instructor').get();
    final Future<QuerySnapshot<Map<String, dynamic>>> studentsSnapFuture =
        usersCollection.where('role', isEqualTo: 'student').get();
    final Future<int> alertsFuture = _countDocuments(
      firestore.collection('alerts'),
    );

    final List<Object> results = await Future.wait<Object>(<Future<Object>>[
      instructorsSnapFuture,
      studentsSnapFuture,
      alertsFuture,
    ]);

    final QuerySnapshot<Map<String, dynamic>> instructorsSnap =
        results[0] as QuerySnapshot<Map<String, dynamic>>;
    final QuerySnapshot<Map<String, dynamic>> studentsSnap =
        results[1] as QuerySnapshot<Map<String, dynamic>>;
    final int alertsCount = results[2] as int;

    final Map<String, int> studentsBySection = <String, int>{};
    for (final QueryDocumentSnapshot<Map<String, dynamic>> doc
        in studentsSnap.docs) {
      final Map<String, dynamic> data = doc.data();
      final String section = normalizeBucket(
        resolveField(data, <String>['section', 'Section']),
        emptyLabel: 'Not assigned',
      );
      studentsBySection[section] = (studentsBySection[section] ?? 0) + 1;
    }

    final Map<String, int> instructorsByDepartment = <String, int>{};
    for (final QueryDocumentSnapshot<Map<String, dynamic>> doc
        in instructorsSnap.docs) {
      final Map<String, dynamic> data = doc.data();
      final String dept = normalizeBucket(
        resolveField(data, <String>[
          'Department',
          'department',
          'departmentName',
        ]),
        emptyLabel: 'Not assigned',
      );
      instructorsByDepartment[dept] = (instructorsByDepartment[dept] ?? 0) + 1;
    }

    Map<String, int> sortByCountDescThenKey(Map<String, int> input) {
      final List<MapEntry<String, int>> entries = input.entries.toList()
        ..sort((MapEntry<String, int> a, MapEntry<String, int> b) {
          final int byCount = b.value.compareTo(a.value);
          if (byCount != 0) return byCount;
          return a.key.toLowerCase().compareTo(b.key.toLowerCase());
        });
      return Map<String, int>.fromEntries(entries);
    }

    return _AdminOverviewStats(
      instructors: instructorsSnap.size,
      students: studentsSnap.size,
      alerts: alertsCount,
      studentsBySection: sortByCountDescThenKey(studentsBySection),
      instructorsByDepartment: sortByCountDescThenKey(instructorsByDepartment),
    );
  }

  Future<void> _refreshOverviewStats() async {
    final Future<_AdminOverviewStats> refreshFuture = _loadOverviewStats();
    setState(() {
      _overviewFuture = refreshFuture;
    });
    await refreshFuture;
  }

  Future<int> _countDocuments(Query<Map<String, dynamic>> query) async {
    final QuerySnapshot<Map<String, dynamic>> snapshot = await query.get();
    return snapshot.size;
  }
}

class _AttendanceReportTemplateMetaDialog extends StatefulWidget {
  const _AttendanceReportTemplateMetaDialog();

  @override
  State<_AttendanceReportTemplateMetaDialog> createState() =>
      _AttendanceReportTemplateMetaDialogState();
}

class _AttendanceReportTemplateMetaDialogState
    extends State<_AttendanceReportTemplateMetaDialog> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final TextEditingController _revNoController = TextEditingController();
  final TextEditingController _effectiveDateController =
      TextEditingController();
  String _documentCodeNo = AttendanceReportTemplateMeta.defaults.documentCodeNo;
  bool _isLoading = true;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _isLoading = true);
    try {
      final AttendanceReportTemplateMeta meta =
          await AttendanceReportTemplateMeta.fetch(_firestore);
      if (!mounted) return;
      _documentCodeNo = meta.documentCodeNo;
      _revNoController.text = meta.revisionNo;
      _effectiveDateController.text = meta.effectiveDate;
    } catch (_) {
      _documentCodeNo = AttendanceReportTemplateMeta.defaults.documentCodeNo;
      _revNoController.text = AttendanceReportTemplateMeta.defaults.revisionNo;
      _effectiveDateController.text =
          AttendanceReportTemplateMeta.defaults.effectiveDate;
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _save() async {
    if (_isSaving) return;
    setState(() => _isSaving = true);
    try {
      final AttendanceReportTemplateMeta meta = AttendanceReportTemplateMeta(
        documentCodeNo: _documentCodeNo.trim(),
        revisionNo: _revNoController.text.trim(),
        effectiveDate: _effectiveDateController.text.trim(),
      );
      await AttendanceReportTemplateMeta.docRef(
        _firestore,
      ).set(meta.toFirestore(), SetOptions(merge: true));
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to save: $error')));
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  void dispose() {
    _revNoController.dispose();
    _effectiveDateController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Attendance Report Header Details'),
      content: SizedBox(
        width: 520,
        child: _isLoading
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Center(child: CircularProgressIndicator()),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  TextField(
                    controller: _revNoController,
                    decoration: const InputDecoration(labelText: 'Rev. No.'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _effectiveDateController,
                    decoration: const InputDecoration(
                      labelText: 'Effective Date',
                      hintText: 'e.g. 03.17.25',
                    ),
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Document Code No. stays fixed in the Word template (currently: $_documentCodeNo).',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _isSaving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: (_isLoading || _isSaving) ? null : _save,
          child: _isSaving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save'),
        ),
      ],
    );
  }
}

class _AdminOverviewStats {
  const _AdminOverviewStats({
    this.instructors = 0,
    this.students = 0,
    this.alerts = 0,
    this.studentsBySection = const <String, int>{},
    this.instructorsByDepartment = const <String, int>{},
  });

  final int instructors;
  final int students;
  final int alerts;

  final Map<String, int> studentsBySection;
  final Map<String, int> instructorsByDepartment;
}

class _AdminStat {
  const _AdminStat({
    required this.label,
    required this.value,
    required this.icon,
  });

  final String label;
  final String value;
  final IconData icon;
}

class _AdminStatPlaceholder extends StatelessWidget {
  const _AdminStatPlaceholder({required this.isWide});

  final bool isWide;

  @override
  Widget build(BuildContext context) {
    final double width = isWide ? 240 : double.infinity;
    return SizedBox(
      width: width,
      child: Card(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const SizedBox(
                height: 24,
                width: 24,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
              const SizedBox(height: 16),
              LinearProgressIndicator(
                backgroundColor: Theme.of(
                  context,
                ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChartBarEntry {
  const _ChartBarEntry({
    required this.label,
    required this.value,
    required this.series,
    required this.barColor,
  });

  final String label;
  final int value;
  final String series;
  final Color barColor;
}

class _EnrollmentCombinedChartCard extends StatelessWidget {
  const _EnrollmentCombinedChartCard({
    required this.studentsTotal,
    required this.instructorsTotal,
    required this.studentsBySection,
    required this.instructorsByDepartment,
  });

  final int studentsTotal;
  final int instructorsTotal;
  final Map<String, int> studentsBySection;
  final Map<String, int> instructorsByDepartment;

  static List<Color> _buildLightPalette({
    required ThemeData theme,
    required Color base,
  }) {
    final Color mixWith = theme.colorScheme.surfaceContainerHighest;
    const List<double> blends = <double>[0.78, 0.70, 0.85, 0.63, 0.90, 0.74];
    return blends
        .map((double t) => Color.lerp(base, mixWith, t) ?? base)
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color studentsColor = theme.colorScheme.primary;
    final Color instructorsColor = theme.colorScheme.secondary;

    final List<Color> studentPalette = _buildLightPalette(
      theme: theme,
      base: studentsColor,
    );
    final List<Color> instructorPalette = _buildLightPalette(
      theme: theme,
      base: instructorsColor,
    );

    final List<MapEntry<String, int>> studentEntries = studentsBySection.entries
        .toList(growable: false);
    final List<MapEntry<String, int>> instructorEntries =
        instructorsByDepartment.entries.toList(growable: false);

    final List<_ChartBarEntry> bars = <_ChartBarEntry>[
      for (int i = 0; i < studentEntries.length; i++)
        _ChartBarEntry(
          label: studentEntries[i].key,
          value: studentEntries[i].value,
          series: 'Students (Section)',
          barColor: studentPalette[i % studentPalette.length],
        ),
      for (int i = 0; i < instructorEntries.length; i++)
        _ChartBarEntry(
          label: instructorEntries[i].key,
          value: instructorEntries[i].value,
          series: 'Instructors (Department)',
          barColor: instructorPalette[i % instructorPalette.length],
        ),
    ];

    final int maxValue = bars.isEmpty
        ? 0
        : bars
              .map(((_ChartBarEntry e) => e.value))
              .reduce((int a, int b) => a > b ? a : b);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    'Users Registered',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  'Students: $studentsTotal • Instructors: $instructorsTotal',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: <Widget>[
                _legendChip('Students (by section)', studentsColor),
                _legendChip('Instructors (by department)', instructorsColor),
              ],
            ),
            const SizedBox(height: 12),
            if (bars.isEmpty)
              Text(
                'No student/instructor data found.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            else
              _MultiSeriesBarChart(bars: bars, maxValue: maxValue),
          ],
        ),
      ),
    );
  }

  static Widget _legendChip(String label, Color color) {
    return Chip(
      avatar: CircleAvatar(backgroundColor: color, radius: 6),
      label: Text(label),
      visualDensity: VisualDensity.compact,
    );
  }
}

class _MultiSeriesBarChart extends StatelessWidget {
  const _MultiSeriesBarChart({required this.bars, required this.maxValue});

  final List<_ChartBarEntry> bars;
  final int maxValue;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    const double barWidth = 70;
    const double chartHeight = 220;

    return SizedBox(
      height: chartHeight,
      child: Scrollbar(
        thumbVisibility: true,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: bars.map((_ChartBarEntry e) {
              final double ratio = maxValue <= 0 ? 0 : (e.value / maxValue);
              final double barHeight = (ratio * 120).clamp(4.0, 120.0);
              final String label = e.label.trim().isEmpty
                  ? '—'
                  : e.label.trim();

              return Padding(
                padding: const EdgeInsets.only(right: 12),
                child: SizedBox(
                  width: barWidth,
                  child: Tooltip(
                    message: '${e.series}\n$label: ${e.value}',
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: <Widget>[
                        Text(
                          e.value.toString(),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 6),
                        Container(
                          height: barHeight,
                          decoration: BoxDecoration(
                            color: e.barColor,
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          label,
                          style: theme.textTheme.labelSmall,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          e.series.startsWith('Students') ? 'Section' : 'Dept',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
      ),
    );
  }
}

class _DepartmentMaintenancePanel extends StatefulWidget {
  const _DepartmentMaintenancePanel();

  @override
  State<_DepartmentMaintenancePanel> createState() =>
      _DepartmentMaintenancePanelState();
}

class _DepartmentMaintenancePanelState
    extends State<_DepartmentMaintenancePanel> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  Future<void> _openDepartmentDialog([
    DocumentSnapshot<Map<String, dynamic>>? existing,
  ]) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) => _DepartmentDialog(existing: existing),
    );
  }

  Future<void> _deleteDepartment(String id) async {
    try {
      await _firestore.collection('departments').doc(id).delete();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Department removed.')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to delete department: $error')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                final bool isCompact = constraints.maxWidth < 520;
                final Widget helpText = const Text(
                  'Manage departments available across programs.',
                );
                final Widget addButton = FilledButton.icon(
                  onPressed: () => _openDepartmentDialog(),
                  icon: const Icon(Icons.add),
                  label: const Text(
                    'Add department',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                );

                if (!isCompact) {
                  return Row(
                    children: <Widget>[
                      Expanded(child: helpText),
                      addButton,
                    ],
                  );
                }

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    helpText,
                    const SizedBox(height: 12),
                    Align(alignment: Alignment.centerLeft, child: addButton),
                  ],
                );
              },
            ),
            const SizedBox(height: 16),
            StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: _firestore
                  .collection('departments')
                  .orderBy('name')
                  .snapshots(),
              builder:
                  (
                    BuildContext context,
                    AsyncSnapshot<QuerySnapshot<Map<String, dynamic>>> snapshot,
                  ) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Text(
                          'No departments found. Add one to get started.',
                        ),
                      );
                    }
                    return ListView.separated(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: snapshot.data!.docs.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (BuildContext context, int index) {
                        final DocumentSnapshot<Map<String, dynamic>> doc =
                            snapshot.data!.docs[index];
                        final Map<String, dynamic> data =
                            doc.data() ?? <String, dynamic>{};
                        final bool isActive =
                            (data['isActive'] as bool?) ?? true;
                        final String abbr = (data['abbr'] as String?) ?? '';
                        const BoxConstraints iconButtonConstraints =
                            BoxConstraints.tightFor(width: 40, height: 40);
                        return ListTile(
                          title: Text(
                            data['name'] as String? ?? 'Unnamed department',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: abbr.isEmpty
                              ? null
                              : Text(
                                  'Abbreviation: $abbr',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              IconButton(
                                constraints: iconButtonConstraints,
                                visualDensity: VisualDensity.compact,
                                icon: const Icon(Icons.edit_outlined),
                                tooltip: 'Edit',
                                onPressed: () => _openDepartmentDialog(doc),
                              ),
                              IconButton(
                                constraints: iconButtonConstraints,
                                visualDensity: VisualDensity.compact,
                                icon: const Icon(Icons.delete_outline),
                                tooltip: 'Delete',
                                onPressed: () => _deleteDepartment(doc.id),
                              ),
                            ],
                          ),
                          leading: Icon(
                            isActive
                                ? Icons.check_circle_outline
                                : Icons.pause_circle_outline,
                            color: isActive
                                ? Colors.green
                                : Colors.orange.shade700,
                          ),
                        );
                      },
                    );
                  },
            ),
          ],
        ),
      ),
    );
  }
}

class _DepartmentDialog extends StatefulWidget {
  const _DepartmentDialog({this.existing});

  final DocumentSnapshot<Map<String, dynamic>>? existing;

  @override
  State<_DepartmentDialog> createState() => _DepartmentDialogState();
}

class _DepartmentDialogState extends State<_DepartmentDialog> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _abbrController = TextEditingController();
  final TextEditingController _headNameController = TextEditingController();
  bool _isActive = true;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    final Map<String, dynamic>? data = widget.existing?.data();
    if (data != null) {
      _nameController.text = (data['name'] as String?) ?? '';
      _abbrController.text = (data['abbr'] as String?) ?? '';
      _headNameController.text = (data['headName'] as String?) ?? '';
      _isActive = (data['isActive'] as bool?) ?? true;
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _abbrController.dispose();
    _headNameController.dispose();
    super.dispose();
  }

  Future<void> _handleSave() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isSaving = true);
    final String headName = _headNameController.text.trim();
    final Map<String, dynamic> payload = <String, dynamic>{
      'name': _nameController.text.trim(),
      'abbr': _abbrController.text.trim(),
      'headName': headName.isEmpty ? null : headName,
      'isActive': _isActive,
      'updatedAt': FieldValue.serverTimestamp(),
    };
    payload.removeWhere((_, Object? value) => value == null);
    final CollectionReference<Map<String, dynamic>> departmentsCollection =
        FirebaseFirestore.instance.collection('departments');
    try {
      if (widget.existing == null) {
        await departmentsCollection.add(<String, dynamic>{
          ...payload,
          'createdAt': FieldValue.serverTimestamp(),
        });
      } else {
        await departmentsCollection.doc(widget.existing!.id).update(payload);
      }
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save department: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool isEditing = widget.existing != null;
    return AlertDialog(
      title: Text(isEditing ? 'Edit department' : 'Add department'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                TextFormField(
                  controller: _nameController,
                  decoration: const InputDecoration(
                    labelText: 'Department name',
                  ),
                  validator: (String? value) =>
                      value == null || value.trim().isEmpty ? 'Required' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _abbrController,
                  decoration: const InputDecoration(labelText: 'Abbreviation'),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _headNameController,
                  decoration: const InputDecoration(
                    labelText: 'Department head (name)',
                    helperText: 'Used for report “Submitted to”.',
                  ),
                ),
                const SizedBox(height: 12),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Active'),
                  value: _isActive,
                  onChanged: (bool value) => setState(() => _isActive = value),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _isSaving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _isSaving ? null : _handleSave,
          child: _isSaving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save'),
        ),
      ],
    );
  }
}

class _DepartmentOption {
  const _DepartmentOption({required this.id, required this.name, this.abbr});

  final String id;
  final String name;
  final String? abbr;
}

class _SubjectCatalogPanel extends StatefulWidget {
  const _SubjectCatalogPanel();

  @override
  State<_SubjectCatalogPanel> createState() => _SubjectCatalogPanelState();
}

class _SubjectCatalogPanelState extends State<_SubjectCatalogPanel> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  bool _isLoadingDepartments = true;
  List<_DepartmentOption> _departments = <_DepartmentOption>[];

  @override
  void initState() {
    super.initState();
    _loadDepartments();
  }

  Future<void> _loadDepartments() async {
    try {
      final QuerySnapshot<Map<String, dynamic>> snapshot = await _firestore
          .collection('departments')
          .orderBy('name')
          .get();
      final List<_DepartmentOption> options = snapshot.docs
          .map(
            (QueryDocumentSnapshot<Map<String, dynamic>> doc) =>
                _DepartmentOption(
                  id: doc.id,
                  name: (doc.data()['name'] as String?) ?? 'Unnamed department',
                  abbr: doc.data()['abbr'] as String?,
                ),
          )
          .toList();
      if (!mounted) return;
      setState(() {
        _departments = options;
        _isLoadingDepartments = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _isLoadingDepartments = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to load departments: $error')),
      );
    }
  }

  Future<void> _openSubjectDialog([
    DocumentSnapshot<Map<String, dynamic>>? existing,
  ]) async {
    if (_departments.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Add a department before creating subjects.'),
        ),
      );
      return;
    }
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) =>
          _SubjectDialog(departments: _departments, existing: existing),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Expanded(
                  child: Text(
                    'Catalogue subjects along with sections and terms.',
                  ),
                ),
                FilledButton.icon(
                  onPressed: _isLoadingDepartments
                      ? null
                      : () => _openSubjectDialog(),
                  icon: const Icon(Icons.add),
                  label: const Text('Add subject'),
                ),
              ],
            ),
            if (_isLoadingDepartments)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 8),
                    Text('Loading departments...'),
                  ],
                ),
              ),
            const SizedBox(height: 16),
            StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: _firestore
                  .collection('subjects')
                  .orderBy('subjectCode')
                  .snapshots(),
              builder:
                  (
                    BuildContext context,
                    AsyncSnapshot<QuerySnapshot<Map<String, dynamic>>> snapshot,
                  ) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Text(
                          'No subjects yet. Add one to begin scheduling.',
                        ),
                      );
                    }
                    return ListView.separated(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: snapshot.data!.docs.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (BuildContext context, int index) {
                        final DocumentSnapshot<Map<String, dynamic>> doc =
                            snapshot.data!.docs[index];
                        final Map<String, dynamic> data =
                            doc.data() ?? <String, dynamic>{};
                        final bool isActive =
                            (data['isActive'] as bool?) ?? true;
                        final List<dynamic> sections =
                            data['sections'] as List<dynamic>? ?? <dynamic>[];
                        final List<dynamic> terms =
                            data['terms'] as List<dynamic>? ?? <dynamic>[];
                        return ListTile(
                          title: Text(
                            '${data['subjectCode'] ?? 'N/A'} • ${data['subjectName'] ?? ''}',
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              if (data['departmentName'] != null)
                                Text(data['departmentName'] as String),
                              if (sections.isNotEmpty)
                                Wrap(
                                  spacing: 6,
                                  runSpacing: -8,
                                  children: sections
                                      .map(
                                        (dynamic value) => Chip(
                                          label: Text(value.toString()),
                                          visualDensity: VisualDensity.compact,
                                        ),
                                      )
                                      .toList(),
                                ),
                              if (terms.isNotEmpty)
                                Wrap(
                                  spacing: 6,
                                  runSpacing: -8,
                                  children: terms
                                      .map(
                                        (dynamic value) => Chip(
                                          label: Text(value.toString()),
                                          visualDensity: VisualDensity.compact,
                                        ),
                                      )
                                      .toList(),
                                ),
                            ],
                          ),
                          leading: Icon(
                            isActive
                                ? Icons.book_outlined
                                : Icons.bookmark_remove_outlined,
                            color: isActive ? Colors.indigo : Colors.grey,
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.edit_note_outlined),
                            onPressed: () => _openSubjectDialog(doc),
                          ),
                        );
                      },
                    );
                  },
            ),
          ],
        ),
      ),
    );
  }
}

class _SubjectDialog extends StatefulWidget {
  const _SubjectDialog({required this.departments, this.existing});

  final List<_DepartmentOption> departments;
  final DocumentSnapshot<Map<String, dynamic>>? existing;

  @override
  State<_SubjectDialog> createState() => _SubjectDialogState();
}

class _SubjectDialogState extends State<_SubjectDialog> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _subjectCodeController = TextEditingController();
  final TextEditingController _subjectNameController = TextEditingController();
  final TextEditingController _sectionInputController = TextEditingController();
  final TextEditingController _termInputController = TextEditingController();
  bool _isActive = true;
  bool _isSaving = false;
  String? _selectedDepartmentId;
  List<String> _sections = <String>[];
  List<String> _terms = <String>[];

  @override
  void initState() {
    super.initState();
    final Map<String, dynamic>? data = widget.existing?.data();
    if (data != null) {
      _subjectCodeController.text = (data['subjectCode'] as String?) ?? '';
      _subjectNameController.text = (data['subjectName'] as String?) ?? '';
      _selectedDepartmentId = data['departmentId'] as String?;
      _sections = (data['sections'] as List<dynamic>? ?? <dynamic>[])
          .map((dynamic value) => value.toString())
          .toList();
      _terms = (data['terms'] as List<dynamic>? ?? <dynamic>[])
          .map((dynamic value) => value.toString())
          .toList();
      _isActive = (data['isActive'] as bool?) ?? true;
    }
  }

  @override
  void dispose() {
    _subjectCodeController.dispose();
    _subjectNameController.dispose();
    _sectionInputController.dispose();
    _termInputController.dispose();
    super.dispose();
  }

  void _addSection() {
    final String value = _sectionInputController.text.trim();
    if (value.isEmpty) return;
    setState(() {
      _sections.add(value);
      _sectionInputController.clear();
    });
  }

  void _addTerm() {
    final String value = _termInputController.text.trim();
    if (value.isEmpty) return;
    setState(() {
      _terms.add(value);
      _termInputController.clear();
    });
  }

  Future<void> _handleSave() async {
    if (!_formKey.currentState!.validate()) return;
    if (_sections.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Add at least one section.')),
      );
      return;
    }
    if (_terms.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Add at least one term.')));
      return;
    }
    setState(() => _isSaving = true);
    final _DepartmentOption department = widget.departments.firstWhere(
      (_DepartmentOption option) => option.id == _selectedDepartmentId!,
    );
    final Map<String, dynamic> payload = <String, dynamic>{
      'subjectCode': _subjectCodeController.text.trim(),
      'subjectName': _subjectNameController.text.trim(),
      'departmentId': department.id,
      'departmentName': department.name,
      'sections': _sections,
      'terms': _terms,
      'isActive': _isActive,
      'updatedAt': FieldValue.serverTimestamp(),
    };
    final CollectionReference<Map<String, dynamic>> subjectCollection =
        FirebaseFirestore.instance.collection('subjects');
    try {
      if (widget.existing == null) {
        await subjectCollection.add(<String, dynamic>{
          ...payload,
          'createdAt': FieldValue.serverTimestamp(),
        });
      } else {
        await subjectCollection.doc(widget.existing!.id).update(payload);
      }
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save subject: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Widget _buildChipInput({
    required String label,
    required TextEditingController controller,
    required VoidCallback onAdd,
    required List<String> values,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(label, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: -8,
          children: values
              .asMap()
              .entries
              .map(
                (MapEntry<int, String> entry) => InputChip(
                  label: Text(entry.value),
                  onDeleted: () => setState(() => values.removeAt(entry.key)),
                ),
              )
              .toList(),
        ),
        Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                controller: controller,
                decoration: const InputDecoration(
                  hintText: 'Enter value and tap add',
                ),
                onSubmitted: (_) => onAdd(),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.add_circle_outline),
              onPressed: onAdd,
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool isEditing = widget.existing != null;
    return AlertDialog(
      title: Text(isEditing ? 'Edit subject' : 'Add subject'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              DropdownButtonFormField<String>(
                isExpanded: true,
                initialValue: _selectedDepartmentId,
                decoration: const InputDecoration(labelText: 'Department'),
                selectedItemBuilder: (BuildContext context) {
                  return widget.departments
                      .map(
                        (_DepartmentOption department) => SizedBox(
                          width: double.infinity,
                          child: Text(
                            department.name,
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                          ),
                        ),
                      )
                      .toList();
                },
                items: widget.departments
                    .map(
                      (_DepartmentOption department) =>
                          DropdownMenuItem<String>(
                            value: department.id,
                            child: SizedBox(
                              width: double.infinity,
                              child: Text(
                                department.name,
                                overflow: TextOverflow.ellipsis,
                                maxLines: 1,
                              ),
                            ),
                          ),
                    )
                    .toList(),
                onChanged: (String? value) =>
                    setState(() => _selectedDepartmentId = value),
                validator: (String? value) => value == null ? 'Required' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _subjectCodeController,
                decoration: const InputDecoration(labelText: 'Subject code'),
                validator: (String? value) =>
                    value == null || value.trim().isEmpty ? 'Required' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _subjectNameController,
                decoration: const InputDecoration(labelText: 'Subject name'),
                validator: (String? value) =>
                    value == null || value.trim().isEmpty ? 'Required' : null,
              ),
              const SizedBox(height: 12),
              _buildChipInput(
                label: 'Sections',
                controller: _sectionInputController,
                onAdd: _addSection,
                values: _sections,
              ),
              const SizedBox(height: 12),
              _buildChipInput(
                label: 'Terms',
                controller: _termInputController,
                onAdd: _addTerm,
                values: _terms,
              ),
              const SizedBox(height: 12),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('Active'),
                value: _isActive,
                onChanged: (bool value) => setState(() => _isActive = value),
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _isSaving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _isSaving ? null : _handleSave,
          child: _isSaving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save'),
        ),
      ],
    );
  }
}

class _SubjectOption {
  const _SubjectOption({
    required this.id,
    required this.subjectCode,
    required this.subjectName,
    required this.sections,
    required this.terms,
    required this.departmentName,
  });

  final String id;
  final String subjectCode;
  final String subjectName;
  final List<String> sections;
  final List<String> terms;
  final String departmentName;
}

class _ClassMaintenancePanel extends StatefulWidget {
  const _ClassMaintenancePanel();

  @override
  State<_ClassMaintenancePanel> createState() => _ClassMaintenancePanelState();
}

class _ClassMaintenancePanelState extends State<_ClassMaintenancePanel> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  bool _isLoadingInstructors = true;
  bool _isLoadingSubjects = true;
  bool _isDeletingClass = false;
  final TextEditingController _classSearchController = TextEditingController();
  String _classSearchQuery = '';
  List<_InstructorOption> _instructors = <_InstructorOption>[];
  List<_SubjectOption> _subjects = <_SubjectOption>[];
  Map<String, String> _instructorLookup = <String, String>{};
  static const List<String> _nameFieldCandidates = <String>[
    'name',
    'fullName',
    'full_name',
    'Full Name',
    'FullName',
  ];
  static const List<String> _emailFieldCandidates = <String>['email', 'Email'];

  @override
  void initState() {
    super.initState();
    _loadInstructors();
    _loadSubjects();
  }

  @override
  void dispose() {
    _classSearchController.dispose();
    super.dispose();
  }

  String _normalizeSearch(String input) {
    return input.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  Iterable<String> _buildScheduleSummaries(Map<String, dynamic> classData) {
    final List<dynamic> schedules =
        (classData['schedules'] as List<dynamic>? ?? <dynamic>[]);
    return schedules
        .map((dynamic entry) {
          if (entry is! Map) return '';
          final Map<String, dynamic> schedule = Map<String, dynamic>.from(
            entry,
          );
          final String type =
              (schedule['type'] as String?)?.toUpperCase().trim() ?? '';
          final String day = (schedule['day'] as String?)?.trim() ?? '';
          final Map<String, dynamic>? start =
              schedule['startTime'] as Map<String, dynamic>?;
          final Map<String, dynamic>? end =
              schedule['endTime'] as Map<String, dynamic>?;

          String formatTime(Map<String, dynamic>? time) {
            if (time == null) return '';
            final Object? hour = time['hour'];
            final int? minute = time['minute'] as int?;
            final String period = (time['period'] as String?)?.trim() ?? '';
            final String hourText = hour == null ? '' : hour.toString();
            final String minuteText = minute == null
                ? ''
                : minute.toString().padLeft(2, '0');
            final String base = [
              hourText,
              minuteText,
            ].where((s) => s.isNotEmpty).join(':');
            return [base, period].where((s) => s.trim().isNotEmpty).join(' ');
          }

          final String formattedStart = formatTime(start);
          final String formattedEnd = formatTime(end);

          return [
            type,
            day,
            [
              formattedStart,
              formattedEnd,
            ].where((s) => s.isNotEmpty).join(' - '),
          ].where((s) => s.trim().isNotEmpty).join(' • ');
        })
        .where((String summary) => summary.trim().isNotEmpty);
  }

  Future<void> _loadInstructors() async {
    try {
      final QuerySnapshot<Map<String, dynamic>> snapshot = await _firestore
          .collection('users')
          .where('role', isEqualTo: 'instructor')
          .get();
      final List<_InstructorOption> options =
          snapshot.docs
              .map(
                (QueryDocumentSnapshot<Map<String, dynamic>> doc) =>
                    _InstructorOption(
                      id: doc.id,
                      displayName: _resolveDisplayName(doc.data()),
                    ),
              )
              .toList()
            ..sort((a, b) => a.displayName.compareTo(b.displayName));
      if (!mounted) return;
      setState(() {
        _instructors = options;
        _instructorLookup = {
          for (final _InstructorOption option in options)
            option.id: option.displayName,
        };
        _isLoadingInstructors = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _isLoadingInstructors = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to load instructors: $error')),
      );
    }
  }

  Future<void> _loadSubjects() async {
    try {
      final QuerySnapshot<Map<String, dynamic>> snapshot = await _firestore
          .collection('subjects')
          .orderBy('subjectCode')
          .get();
      final List<_SubjectOption> options = snapshot.docs
          .map(
            (QueryDocumentSnapshot<Map<String, dynamic>> doc) => _SubjectOption(
              id: doc.id,
              subjectCode:
                  (doc.data()['subjectCode'] as String?) ?? 'Uncoded subject',
              subjectName:
                  (doc.data()['subjectName'] as String?) ?? 'Unnamed subject',
              sections: List<String>.from(
                (doc.data()['sections'] as List<dynamic>? ?? <dynamic>[]).map(
                  (dynamic value) => value.toString(),
                ),
              ),
              terms: List<String>.from(
                (doc.data()['terms'] as List<dynamic>? ?? <dynamic>[]).map(
                  (dynamic value) => value.toString(),
                ),
              ),
              departmentName:
                  (doc.data()['departmentName'] as String?) ?? 'Unknown dept',
            ),
          )
          .toList();
      options.sort((a, b) => a.subjectCode.compareTo(b.subjectCode));
      if (!mounted) return;
      setState(() {
        _subjects = options;
        _isLoadingSubjects = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _isLoadingSubjects = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to load subjects: $error')),
      );
    }
  }

  String _resolveDisplayName(Map<String, dynamic> data) {
    for (final String key in _nameFieldCandidates) {
      final Object? value = data[key];
      if (value is String && value.trim().isNotEmpty) {
        return value.trim();
      }
    }
    for (final String key in _emailFieldCandidates) {
      final Object? value = data[key];
      if (value is String && value.trim().isNotEmpty) {
        return value.trim();
      }
    }
    return 'Unknown';
  }

  Future<void> _openClassDialog({
    DocumentSnapshot<Map<String, dynamic>>? existing,
  }) async {
    if (_isLoadingInstructors || _isLoadingSubjects) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Lists are still loading. Please wait a moment.'),
        ),
      );
      return;
    }
    if (_subjects.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Add subjects before configuring class schedules.'),
        ),
      );
      return;
    }
    final bool? updated = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) => _ClassEditorDialog(
        instructors: _instructors,
        subjects: _subjects,
        existing: existing,
      ),
    );
    if (updated == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            existing == null
                ? 'Class created successfully.'
                : 'Class updated successfully.',
          ),
        ),
      );
    }
  }

  Future<void> _deleteClass({required String id, required String label}) async {
    if (_isDeletingClass) return;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Remove class?'),
        content: Text(
          'This will permanently delete "$label" from Class Maintenance. This cannot be undone.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _isDeletingClass = true);
    try {
      await _firestore.collection('classes').doc(id).delete();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Removed class: $label')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to remove class: $error')));
    } finally {
      if (mounted) setState(() => _isDeletingClass = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Expanded(
                  child: Text(
                    'Manage subject sections, schedules, and instructor assignments.',
                  ),
                ),
                FilledButton.icon(
                  onPressed:
                      (_isLoadingInstructors ||
                          _isLoadingSubjects ||
                          _subjects.isEmpty)
                      ? null
                      : () => _openClassDialog(),
                  icon: const Icon(Icons.add),
                  label: const Text('Add class'),
                ),
              ],
            ),
            if (_isLoadingInstructors || _isLoadingSubjects)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 8),
                    Text('Loading instructors & subjects...'),
                  ],
                ),
              ),
            if (!_isLoadingSubjects && _subjects.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'No subjects available yet. Configure the subject catalog first.',
                ),
              ),
            const SizedBox(height: 16),
            TextField(
              controller: _classSearchController,
              decoration: InputDecoration(
                hintText: 'Search by section, subject, schedule, or instructor',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _classSearchQuery.trim().isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear',
                        icon: const Icon(Icons.close),
                        onPressed: () {
                          _classSearchController.clear();
                          setState(() => _classSearchQuery = '');
                        },
                      ),
              ),
              onChanged: (String value) {
                setState(() => _classSearchQuery = value);
              },
            ),
            const SizedBox(height: 12),
            StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: _firestore
                  .collection('classes')
                  .orderBy('subjectCode')
                  .snapshots(),
              builder:
                  (
                    BuildContext context,
                    AsyncSnapshot<QuerySnapshot<Map<String, dynamic>>> snapshot,
                  ) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: Text('No classes configured yet.'),
                      );
                    }
                    final List<QueryDocumentSnapshot<Map<String, dynamic>>>
                    docs = snapshot.data!.docs;
                    final String query = _normalizeSearch(_classSearchQuery);
                    final List<QueryDocumentSnapshot<Map<String, dynamic>>>
                    filteredDocs = query.isEmpty
                        ? docs
                        : docs.where((
                            QueryDocumentSnapshot<Map<String, dynamic>> doc,
                          ) {
                            final Map<String, dynamic> data = doc.data();
                            final String subjectCode =
                                (data['subjectCode'] as String?) ?? '';
                            final String subjectName =
                                (data['subjectName'] as String?) ?? '';
                            final String section =
                                (data['section'] as String?) ?? '';
                            final String term = (data['term'] as String?) ?? '';
                            final String instructorId =
                                (data['instructorId'] as String?) ?? '';
                            final String instructorLabel =
                                _instructorLookup[instructorId] ?? '';
                            final String departmentName =
                                (data['departmentName'] as String?) ?? '';

                            final Iterable<String> scheduleSummaries =
                                _buildScheduleSummaries(data);

                            final String haystack = _normalizeSearch(
                              <String>[
                                    subjectCode,
                                    subjectName,
                                    section,
                                    term,
                                    instructorLabel,
                                    departmentName,
                                    ...scheduleSummaries,
                                  ]
                                  .where(
                                    (String value) => value.trim().isNotEmpty,
                                  )
                                  .join(' | '),
                            );
                            return haystack.contains(query);
                          }).toList();

                    if (filteredDocs.isEmpty) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 24),
                        child: Text(
                          query.isEmpty
                              ? 'No classes configured yet.'
                              : 'No classes match "${_classSearchQuery.trim()}".',
                        ),
                      );
                    }
                    return ListView.separated(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: filteredDocs.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (BuildContext context, int index) {
                        final QueryDocumentSnapshot<Map<String, dynamic>> doc =
                            filteredDocs[index];
                        final Map<String, dynamic> data = doc.data();
                        final String subjectCode =
                            (data['subjectCode'] as String?) ?? 'N/A';
                        final String subjectName =
                            (data['subjectName'] as String?) ?? '';
                        final String section =
                            (data['section'] as String?) ?? 'Unknown';
                        final String term =
                            (data['term'] as String?) ?? 'Unknown';
                        final String instructorId =
                            (data['instructorId'] as String?) ?? 'Unassigned';
                        final String departmentName =
                            (data['departmentName'] as String?) ?? '';
                        final Iterable<String> scheduleSummaries =
                            _buildScheduleSummaries(data);
                        final String classLabel = '$subjectCode • $section';
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(classLabel),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              if (subjectName.isNotEmpty) Text(subjectName),
                              if (departmentName.isNotEmpty)
                                Text(departmentName),
                              Text('Term: $term'),
                              Text(
                                'Instructor: ${_instructorLookup[instructorId] ?? instructorId}',
                              ),
                              ...scheduleSummaries.map(Text.new),
                            ],
                          ),
                          trailing: PopupMenuButton<String>(
                            tooltip: 'Class actions',
                            onSelected: (String value) {
                              switch (value) {
                                case 'edit':
                                  _openClassDialog(existing: doc);
                                  return;
                                case 'delete':
                                  _deleteClass(id: doc.id, label: classLabel);
                                  return;
                              }
                            },
                            itemBuilder: (BuildContext context) {
                              return <PopupMenuEntry<String>>[
                                const PopupMenuItem<String>(
                                  value: 'edit',
                                  child: ListTile(
                                    leading: Icon(Icons.edit_note_outlined),
                                    title: Text('Edit'),
                                  ),
                                ),
                                PopupMenuItem<String>(
                                  value: 'delete',
                                  enabled: !_isDeletingClass,
                                  child: const ListTile(
                                    leading: Icon(Icons.delete_outline),
                                    title: Text('Remove'),
                                  ),
                                ),
                              ];
                            },
                          ),
                        );
                      },
                    );
                  },
            ),
          ],
        ),
      ),
    );
  }
}

class _InstructorOption {
  const _InstructorOption({required this.id, required this.displayName});

  final String id;
  final String displayName;
}

class _ClassEditorDialog extends StatefulWidget {
  const _ClassEditorDialog({
    required this.instructors,
    required this.subjects,
    this.existing,
  });

  final List<_InstructorOption> instructors;
  final List<_SubjectOption> subjects;
  final DocumentSnapshot<Map<String, dynamic>>? existing;

  @override
  State<_ClassEditorDialog> createState() => _ClassEditorDialogState();
}

class _ClassEditorDialogState extends State<_ClassEditorDialog> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _subjectCodeController = TextEditingController();
  final TextEditingController _subjectNameController = TextEditingController();
  bool _isSaving = false;
  String? _selectedInstructor;
  String? _selectedSubjectId;
  String? _selectedSection;
  String? _selectedTerm;
  List<String> _availableSections = <String>[];
  List<String> _availableTerms = <String>[];
  List<_ScheduleDraft> _schedules = <_ScheduleDraft>[];

  @override
  void initState() {
    super.initState();
    final Map<String, dynamic>? data = widget.existing?.data();
    if (data != null) {
      _subjectCodeController.text = (data['subjectCode'] as String?) ?? '';
      _subjectNameController.text = (data['subjectName'] as String?) ?? '';
      _selectedSection = data['section'] as String?;
      _selectedTerm = data['term'] as String?;
      _selectedSubjectId = data['subjectId'] as String?;
      _selectedInstructor = data['instructorId'] as String?;
      final List<dynamic> rawSchedules =
          (data['schedules'] as List<dynamic>? ?? <dynamic>[]);
      _schedules = rawSchedules
          .map(
            (dynamic item) =>
                _ScheduleDraft.fromMap(item as Map<String, dynamic>),
          )
          .toList();
    }
    if (_selectedSection != null && _availableSections.isEmpty) {
      _availableSections = <String>[_selectedSection!];
    }
    if (_selectedTerm != null && _availableTerms.isEmpty) {
      _availableTerms = <String>[_selectedTerm!];
    }
    final _SubjectOption? initialSubject =
        _resolveInitialSubject(data) ??
        _resolveSubjectByCode(_subjectCodeController.text);
    if (initialSubject != null) {
      _applySubjectSelection(
        initialSubject,
        preferredSection: _selectedSection,
        preferredTerm: _selectedTerm,
      );
    } else if (widget.existing == null && widget.subjects.isNotEmpty) {
      _applySubjectSelection(widget.subjects.first);
    }
    if (_schedules.isEmpty) {
      _schedules = <_ScheduleDraft>[_ScheduleDraft()];
    }
  }

  @override
  void dispose() {
    _subjectCodeController.dispose();
    _subjectNameController.dispose();
    super.dispose();
  }

  _SubjectOption? _resolveInitialSubject(Map<String, dynamic>? data) {
    if (data == null) return null;
    final String? subjectId = data['subjectId'] as String?;
    if (subjectId == null) {
      return null;
    }
    return _resolveSubjectById(subjectId);
  }

  _SubjectOption? _resolveSubjectById(String? id) {
    if (id == null) return null;
    try {
      return widget.subjects.firstWhere((subject) => subject.id == id);
    } catch (_) {
      return null;
    }
  }

  _SubjectOption? _resolveSubjectByCode(String? code) {
    final String normalized = code?.trim() ?? '';
    if (normalized.isEmpty) return null;
    try {
      return widget.subjects.firstWhere(
        (subject) => subject.subjectCode == normalized,
      );
    } catch (_) {
      return null;
    }
  }

  void _applySubjectSelection(
    _SubjectOption subject, {
    String? preferredSection,
    String? preferredTerm,
  }) {
    _selectedSubjectId = subject.id;
    _subjectCodeController.text = subject.subjectCode;
    _subjectNameController.text = subject.subjectName;
    _availableSections = List<String>.from(subject.sections);
    _availableTerms = List<String>.from(subject.terms);
    if (preferredSection != null &&
        _availableSections.contains(preferredSection)) {
      _selectedSection = preferredSection;
    } else {
      _selectedSection = _availableSections.isNotEmpty
          ? _availableSections.first
          : null;
    }
    if (preferredTerm != null && _availableTerms.contains(preferredTerm)) {
      _selectedTerm = preferredTerm;
    } else {
      _selectedTerm = _availableTerms.isNotEmpty ? _availableTerms.first : null;
    }
  }

  Future<void> _handleSave() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    if (_selectedSubjectId == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Please select a subject.')));
      return;
    }
    if (_selectedSection == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select a section for this class.')),
      );
      return;
    }
    if (_selectedTerm == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select a term for this class.')),
      );
      return;
    }
    if (_selectedInstructor == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select an instructor.')),
      );
      return;
    }
    if (_schedules.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Add at least one schedule entry.')),
      );
      return;
    }
    setState(() => _isSaving = true);
    final _SubjectOption? subject = _resolveSubjectById(_selectedSubjectId);
    if (subject == null) {
      if (mounted) {
        setState(() => _isSaving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Selected subject is no longer available.'),
          ),
        );
      }
      return;
    }
    final Map<String, dynamic> payload = <String, dynamic>{
      'subjectId': subject.id,
      'subjectCode': subject.subjectCode,
      'subjectName': subject.subjectName,
      'departmentName': subject.departmentName,
      'section': _selectedSection,
      'term': _selectedTerm,
      'instructorId': _selectedInstructor,
      'schedules': _schedules.map((schedule) => schedule.toJson()).toList(),
      'hasLab': _schedules.any((schedule) => schedule.type == 'laboratory'),
      'updatedAt': FieldValue.serverTimestamp(),
    };
    final CollectionReference<Map<String, dynamic>> classesCollection =
        FirebaseFirestore.instance.collection('classes');
    try {
      if (widget.existing == null) {
        await classesCollection.add(<String, dynamic>{
          ...payload,
          'createdAt': FieldValue.serverTimestamp(),
        });
      } else {
        await classesCollection.doc(widget.existing!.id).update(payload);
      }
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to save class: $error')));
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  void _addSchedule() {
    setState(() => _schedules.add(_ScheduleDraft()));
  }

  void _removeSchedule(int index) {
    setState(() {
      _schedules.removeAt(index);
      if (_schedules.isEmpty) {
        _schedules.add(_ScheduleDraft());
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final Size screenSize = MediaQuery.of(context).size;
    return AlertDialog(
      title: Text(widget.existing == null ? 'Add class' : 'Edit class'),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 600,
          maxHeight: screenSize.height * 0.8,
        ),
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                DropdownButtonFormField<String>(
                  initialValue: _selectedSubjectId,
                  decoration: const InputDecoration(labelText: 'Subject'),
                  items: widget.subjects
                      .map(
                        (_SubjectOption option) => DropdownMenuItem<String>(
                          value: option.id,
                          child: Text(
                            '${option.subjectCode} • ${option.subjectName}',
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (String? value) {
                    if (value == null) return;
                    final _SubjectOption? selection = _resolveSubjectById(
                      value,
                    );
                    setState(() {
                      if (selection != null) {
                        _applySubjectSelection(selection);
                      }
                    });
                  },
                  validator: (String? value) =>
                      value == null ? 'Required' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _subjectCodeController,
                  readOnly: true,
                  decoration: const InputDecoration(labelText: 'Subject code'),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _subjectNameController,
                  readOnly: true,
                  decoration: const InputDecoration(labelText: 'Subject name'),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _selectedSection,
                  decoration: const InputDecoration(labelText: 'Section'),
                  items: _availableSections
                      .map(
                        (String section) => DropdownMenuItem<String>(
                          value: section,
                          child: Text(section),
                        ),
                      )
                      .toList(),
                  onChanged: (String? value) =>
                      setState(() => _selectedSection = value),
                  validator: (String? value) =>
                      value == null ? 'Required' : null,
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _selectedTerm,
                  decoration: const InputDecoration(labelText: 'Term'),
                  items: _availableTerms
                      .map(
                        (String term) => DropdownMenuItem<String>(
                          value: term,
                          child: Text(term),
                        ),
                      )
                      .toList(),
                  onChanged: (String? value) =>
                      setState(() => _selectedTerm = value),
                  validator: (String? value) =>
                      value == null ? 'Required' : null,
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _selectedInstructor,
                  decoration: const InputDecoration(labelText: 'Instructor'),
                  items: widget.instructors
                      .map(
                        (_InstructorOption instructor) =>
                            DropdownMenuItem<String>(
                              value: instructor.id,
                              child: Text(instructor.displayName),
                            ),
                      )
                      .toList(),
                  onChanged: (String? value) =>
                      setState(() => _selectedInstructor = value),
                  validator: (String? value) =>
                      value == null ? 'Required' : null,
                ),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Schedules',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Column(
                  children: List<Widget>.generate(_schedules.length, (
                    int index,
                  ) {
                    final _ScheduleDraft draft = _schedules[index];
                    return _ScheduleCard(
                      draft: draft,
                      onChanged: () => setState(() {}),
                      onRemove: () => _removeSchedule(index),
                    );
                  }),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: _addSchedule,
                    icon: const Icon(Icons.add_circle_outline),
                    label: const Text('Add schedule entry'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _isSaving
              ? null
              : () => Navigator.of(context).maybePop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _isSaving ? null : _handleSave,
          child: _isSaving
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save'),
        ),
      ],
    );
  }
}

class _ScheduleCard extends StatelessWidget {
  const _ScheduleCard({
    required this.draft,
    required this.onChanged,
    required this.onRemove,
  });

  final _ScheduleDraft draft;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  static const List<String> _types = <String>['lecture', 'laboratory'];
  static const List<String> _days = <String>[
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];
  static final List<int> _hours = List<int>.generate(
    12,
    (int index) => index + 1,
  );
  static const List<int> _minutes = <int>[0, 15, 30, 45];
  static const List<String> _periods = <String>['AM', 'PM'];

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: draft.type,
                    decoration: const InputDecoration(labelText: 'Type'),
                    items: _types
                        .map(
                          (String value) => DropdownMenuItem<String>(
                            value: value,
                            child: Text(value.capitalize()),
                          ),
                        )
                        .toList(),
                    onChanged: (String? value) {
                      if (value == null) return;
                      draft.type = value;
                      onChanged();
                    },
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: draft.day,
                    decoration: const InputDecoration(labelText: 'Day'),
                    items: _days
                        .map(
                          (String value) => DropdownMenuItem<String>(
                            value: value,
                            child: Text(value),
                          ),
                        )
                        .toList(),
                    onChanged: (String? value) {
                      if (value == null) return;
                      draft.day = value;
                      onChanged();
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _TimeRow(
              label: 'Start time',
              time: draft.startTime,
              onChanged: onChanged,
              hours: _hours,
              minutes: _minutes,
              periods: _periods,
            ),
            const SizedBox(height: 8),
            _TimeRow(
              label: 'End time',
              time: draft.endTime,
              onChanged: onChanged,
              hours: _hours,
              minutes: _minutes,
              periods: _periods,
            ),
            const SizedBox(height: 12),
            TextFormField(
              initialValue: draft.room,
              decoration: const InputDecoration(labelText: 'Room'),
              onChanged: (String value) {
                draft.room = value;
                onChanged();
              },
              validator: (String? value) =>
                  value == null || value.trim().isEmpty ? 'Required' : null,
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: onRemove,
                icon: const Icon(Icons.delete_outline),
                label: const Text('Remove entry'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TimeRow extends StatelessWidget {
  const _TimeRow({
    required this.label,
    required this.time,
    required this.onChanged,
    required this.hours,
    required this.minutes,
    required this.periods,
  });

  final String label;
  final _ScheduleTime time;
  final VoidCallback onChanged;
  final List<int> hours;
  final List<int> minutes;
  final List<String> periods;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Expanded(
          child: DropdownButtonFormField<int>(
            initialValue: time.hour,
            decoration: InputDecoration(labelText: label),
            items: hours
                .map(
                  (int value) => DropdownMenuItem<int>(
                    value: value,
                    child: Text(value.toString()),
                  ),
                )
                .toList(),
            onChanged: (int? value) {
              if (value == null) return;
              time.hour = value;
              onChanged();
            },
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: DropdownButtonFormField<int>(
            initialValue: time.minute,
            decoration: const InputDecoration(labelText: 'Minute'),
            items: minutes
                .map(
                  (int value) => DropdownMenuItem<int>(
                    value: value,
                    child: Text(value.toString().padLeft(2, '0')),
                  ),
                )
                .toList(),
            onChanged: (int? value) {
              if (value == null) return;
              time.minute = value;
              onChanged();
            },
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: DropdownButtonFormField<String>(
            initialValue: time.period,
            decoration: const InputDecoration(labelText: 'Period'),
            items: periods
                .map(
                  (String value) => DropdownMenuItem<String>(
                    value: value,
                    child: Text(value),
                  ),
                )
                .toList(),
            onChanged: (String? value) {
              if (value == null) return;
              time.period = value;
              onChanged();
            },
          ),
        ),
      ],
    );
  }
}

class _ScheduleDraft {
  _ScheduleDraft({
    this.type = 'lecture',
    this.day = 'Monday',
    _ScheduleTime? start,
    _ScheduleTime? end,
    this.room = '',
  }) : startTime = start ?? _ScheduleTime(hour: 8, minute: 0, period: 'AM'),
       endTime = end ?? _ScheduleTime(hour: 9, minute: 0, period: 'AM');

  factory _ScheduleDraft.fromMap(Map<String, dynamic> map) {
    return _ScheduleDraft(
      type: (map['type'] as String?) ?? 'lecture',
      day: (map['day'] as String?) ?? 'Monday',
      start: _ScheduleTime.fromMap(map['startTime'] as Map<String, dynamic>?),
      end: _ScheduleTime.fromMap(map['endTime'] as Map<String, dynamic>?),
      room: (map['room'] as String?) ?? '',
    );
  }

  String type;
  String day;
  final _ScheduleTime startTime;
  final _ScheduleTime endTime;
  String room;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'type': type,
    'day': day,
    'startTime': startTime.toJson(),
    'endTime': endTime.toJson(),
    'room': room,
  };
}

class _ScheduleTime {
  _ScheduleTime({
    required this.hour,
    required this.minute,
    required this.period,
  });

  factory _ScheduleTime.fromMap(Map<String, dynamic>? map) {
    if (map == null) {
      return _ScheduleTime(hour: 8, minute: 0, period: 'AM');
    }
    return _ScheduleTime(
      hour: (map['hour'] as num?)?.toInt() ?? 8,
      minute: (map['minute'] as num?)?.toInt() ?? 0,
      period: (map['period'] as String?) ?? 'AM',
    );
  }

  int hour;
  int minute;
  String period;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'hour': hour,
    'minute': minute,
    'period': period,
  };
}

extension on String {
  String capitalize() =>
      isEmpty ? this : '${this[0].toUpperCase()}${substring(1)}';
}

class _AdminStatCard extends StatelessWidget {
  const _AdminStatCard({required this.stat, required this.isWide});

  final _AdminStat stat;
  final bool isWide;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final double width = isWide ? 240 : double.infinity;
    return SizedBox(
      width: width,
      child: Card(
        elevation: 4,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(stat.icon, color: colors.primary),
              const SizedBox(height: 12),
              Text(
                stat.value,
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              Text(stat.label, style: Theme.of(context).textTheme.bodyMedium),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionNavItem {
  const _SectionNavItem(this.section, this.label, this.icon);

  final _AdminSection section;
  final String label;
  final IconData icon;
}

class _UserManagementPanel extends StatefulWidget {
  const _UserManagementPanel();

  @override
  State<_UserManagementPanel> createState() => _UserManagementPanelState();
}

enum _BulkUserAction {
  editProfile,
  fixFaceEnrollment,
  migrateFaceEnrollmentToVps,
  clearFaceEnrollment,
  deleteUser,
}

class _BulkProgressInfo {
  _BulkProgressInfo({required this.label, required this.total});

  final String label;
  final int total;
  int processed = 0;
  int success = 0;
  int failed = 0;
  String? currentLabel;

  double? get fraction {
    if (total <= 0) return null;
    final int clamped = processed.clamp(0, total);
    return clamped / total;
  }
}

class _UserManagementPanelState extends State<_UserManagementPanel> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseFunctions _functions = FirebaseFunctions.instanceFor(
    region: 'us-central1',
  );
  final ScrollController _allUsersScrollController = ScrollController();
  final TextEditingController _userSearchController = TextEditingController();

  bool _showStudents = true;
  bool _showInstructors = true;
  String _searchQuery = '';

  bool _multiSelectEnabled = false;
  bool _bulkActionRunning = false;
  _BulkProgressInfo? _bulkProgress;
  final Set<String> _selectedUserIds = <String>{};

  static const List<int> _usersRowsPerPageOptions = <int>[10, 20, 30, 50, 100];
  int _usersRowsPerPage = 20;
  int _usersPageIndex = 0;

  Widget _buildBulkProgressBanner() {
    final _BulkProgressInfo? p = _bulkProgress;
    if (!_bulkActionRunning || p == null) return const SizedBox.shrink();

    final String counts =
        '${p.processed}/${p.total} • Success ${p.success} • Failed ${p.failed}';
    final String current = (p.currentLabel == null || p.currentLabel!.isEmpty)
        ? ''
        : '\nCurrent: ${p.currentLabel}';

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '${p.label}…',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              LinearProgressIndicator(value: p.fraction),
              const SizedBox(height: 8),
              Text('$counts$current'),
            ],
          ),
        ),
      ),
    );
  }

  static const int _usersFetchPageSize = 100;
  static const int _selectAllFetchPageSize = 500;
  static const int _selectAllHardCap = 5000;
  bool _loadingUsers = false;
  bool _loadingMore = false;
  bool _selectingAll = false;
  bool _hasMoreUsers = true;
  QueryDocumentSnapshot<Map<String, dynamic>>? _lastUserDoc;
  List<QueryDocumentSnapshot<Map<String, dynamic>>> _loadedUserDocs =
      <QueryDocumentSnapshot<Map<String, dynamic>>>[];

  void _scrollUsersListToTop() {
    if (!_allUsersScrollController.hasClients) return;
    _allUsersScrollController.jumpTo(0);
  }

  int _totalPagesFor(int totalRows) {
    if (totalRows <= 0) return 1;
    return ((totalRows + _usersRowsPerPage - 1) ~/ _usersRowsPerPage).clamp(
      1,
      1 << 30,
    );
  }

  void _resetUsersPagination() {
    _usersPageIndex = 0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollUsersListToTop();
    });
  }

  void _goToPrevUsersPage() {
    if (_usersPageIndex <= 0) return;
    setState(() {
      _usersPageIndex--;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollUsersListToTop();
    });
  }

  Future<void> _goToNextUsersPage() async {
    if (_loadingUsers || _loadingMore) return;

    final int totalRows = _filteredUserDocs().length;
    final int totalPages = _totalPagesFor(totalRows);

    if (_usersPageIndex < totalPages - 1) {
      setState(() {
        _usersPageIndex++;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollUsersListToTop();
      });
      return;
    }

    if (_hasMoreUsers) {
      await _loadMoreUsers();
      if (!mounted) return;

      final int newTotalRows = _filteredUserDocs().length;
      final int newTotalPages = _totalPagesFor(newTotalRows);
      if (_usersPageIndex < newTotalPages - 1) {
        setState(() {
          _usersPageIndex++;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _scrollUsersListToTop();
        });
      }
    }
  }

  final Map<String, Map<String, dynamic>> _userDocPatches =
      <String, Map<String, dynamic>>{};

  final Map<String, bool> _vpsEnrollmentCache = <String, bool>{};
  final Set<String> _vpsEnrollmentInFlight = <String>{};

  static const String _kVpsEnrollmentOverrideKey = '_vpsEnrolled';

  bool _hasLegacyFaceEnrollment(Map<String, dynamic> data) {
    return ((data['faceEmbeds'] is List) &&
            (data['faceEmbeds'] as List).isNotEmpty) ||
        ((data['faceEmbed'] is List) && (data['faceEmbed'] as List).isNotEmpty);
  }

  Map<String, dynamic> _patchedUserData(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final Map<String, dynamic>? patch = _userDocPatches[doc.id];
    if (patch == null || patch.isEmpty) {
      return doc.data();
    }
    return <String, dynamic>{...doc.data(), ...patch};
  }

  bool _hasFaceEnrollment(String uid, Map<String, dynamic> data) {
    final Object? override = data[_kVpsEnrollmentOverrideKey];
    if (override is bool) {
      return override;
    }

    final bool? cached = _vpsEnrollmentCache[uid];
    if (cached != null) {
      return cached;
    }
    return ((data['faceEmbeds'] is List) &&
            (data['faceEmbeds'] as List).isNotEmpty) ||
        ((data['faceEmbed'] is List) && (data['faceEmbed'] as List).isNotEmpty);
  }

  Future<void> _ensureVpsEnrollmentCached(String uid) async {
    if (_vpsEnrollmentCache.containsKey(uid)) return;
    if (_vpsEnrollmentInFlight.contains(uid)) return;
    _vpsEnrollmentInFlight.add(uid);

    try {
      const VpsEmbeddingsApiClient vpsClient = VpsEmbeddingsApiClient();
      bool enrolled;
      try {
        enrolled =
            (await vpsClient.getEmbeddingForUid(
              uid,
              forceRefreshToken: false,
            )) !=
            null;
      } on VpsEmbeddingsApiException catch (e) {
        if (e.statusCode == 401 || e.statusCode == 403) {
          enrolled =
              (await vpsClient.getEmbeddingForUid(
                uid,
                forceRefreshToken: true,
              )) !=
              null;
        } else {
          rethrow;
        }
      }

      _vpsEnrollmentCache[uid] = enrolled;
      _applyVpsEnrollmentPatch(uid, enrolled);
      if (mounted) {
        setState(() {});
      }
    } catch (error, stackTrace) {
      debugPrint('VPS enrollment check failed for $uid: $error\n$stackTrace');
    } finally {
      _vpsEnrollmentInFlight.remove(uid);
    }
  }

  bool _isAdminAccount(String uid, Map<String, dynamic> data) {
    final String role = ((data['role'] as String?) ?? '').trim().toLowerCase();
    if (role == 'admin') return true;
    if (data['isAdmin'] == true || data['admin'] == true) return true;

    // Also hide the currently signed-in admin account from this module.
    final String? currentUid = FirebaseAuth.instance.currentUser?.uid;
    if (currentUid != null && currentUid == uid) return true;

    return false;
  }

  List<QueryDocumentSnapshot<Map<String, dynamic>>> _filteredUserDocs() {
    if (_loadedUserDocs.isEmpty) {
      return const <QueryDocumentSnapshot<Map<String, dynamic>>>[];
    }

    final String q = _searchQuery;

    final List<QueryDocumentSnapshot<Map<String, dynamic>>> docs =
        _loadedUserDocs
            .where((QueryDocumentSnapshot<Map<String, dynamic>> doc) {
              final Map<String, dynamic> data = _patchedUserData(doc);
              return !_isAdminAccount(doc.id, data);
            })
            .where((QueryDocumentSnapshot<Map<String, dynamic>> doc) {
              final Map<String, dynamic> data = _patchedUserData(doc);
              final String role = ((data['role'] as String?) ?? '')
                  .toLowerCase();
              if (role == 'student') {
                return _showStudents;
              }
              if (role == 'instructor') {
                return _showInstructors;
              }
              return true;
            })
            .where((QueryDocumentSnapshot<Map<String, dynamic>> doc) {
              if (q.isEmpty) return true;
              final Map<String, dynamic> data = _patchedUserData(doc);
              return _buildSearchHaystack(data, doc.id).contains(q);
            })
            .toList(growable: true);

    docs.sort((a, b) {
      final Map<String, dynamic> dataA = _patchedUserData(a);
      final Map<String, dynamic> dataB = _patchedUserData(b);
      final String rawA = _resolveDisplayName(dataA, a.id).trim();
      final String rawB = _resolveDisplayName(dataB, b.id).trim();
      final String keyA = (rawA.isEmpty ? a.id : rawA).toLowerCase();
      final String keyB = (rawB.isEmpty ? b.id : rawB).toLowerCase();
      final int cmp = keyA.compareTo(keyB);
      if (cmp != 0) return cmp;
      final int rawCmp = rawA.compareTo(rawB);
      if (rawCmp != 0) return rawCmp;
      return a.id.compareTo(b.id);
    });

    return docs;
  }

  void _applyClearedEnrollmentPatch(String uid) {
    _userDocPatches[uid] = <String, dynamic>{_kVpsEnrollmentOverrideKey: false};
  }

  void _applyVpsEnrollmentPatch(String uid, bool enrolled) {
    final Map<String, dynamic> existing =
        _userDocPatches[uid] ?? const <String, dynamic>{};
    _userDocPatches[uid] = <String, dynamic>{
      ...existing,
      _kVpsEnrollmentOverrideKey: enrolled,
    };
  }

  List<double> _l2NormalizeVector(List<double> v) {
    if (v.isEmpty) return <double>[];
    double sumSquares = 0;
    for (final double x in v) {
      sumSquares += x * x;
    }
    if (sumSquares <= 0) return <double>[];
    final double inv = 1.0 / math.sqrt(sumSquares);
    return v.map((double x) => x * inv).toList(growable: false);
  }

  List<double>? _extractLegacyEmbedding(Map<String, dynamic> data) {
    final Object? rawMulti = data['faceEmbeds'];
    if (rawMulti is List) {
      for (final Object? item in rawMulti) {
        List<num>? nums;
        if (item is List) {
          nums = item.whereType<num>().toList(growable: false);
        } else if (item is Map) {
          final Object? v = item['v'];
          if (v is List) {
            nums = v.whereType<num>().toList(growable: false);
          }
        }
        if (nums == null || nums.isEmpty) continue;
        final List<double> vec = nums
            .where((num n) => n.isFinite)
            .map((num n) => n.toDouble())
            .toList(growable: false);
        if (vec.isNotEmpty) return vec;
      }
    }

    final Object? rawSingle = data['faceEmbed'];
    if (rawSingle is List) {
      final List<double> vec = rawSingle
          .whereType<num>()
          .where((num n) => n.isFinite)
          .map((num n) => n.toDouble())
          .toList(growable: false);
      if (vec.isNotEmpty) return vec;
    }

    return null;
  }

  Future<void> _refreshUsersById(Iterable<String> uids) async {
    final List<String> ids = uids.toSet().toList(growable: false);
    if (ids.isEmpty) return;

    // Firestore `whereIn` is limited to 10 values.
    const int chunkSize = 10;
    final Map<String, QueryDocumentSnapshot<Map<String, dynamic>>> freshById =
        <String, QueryDocumentSnapshot<Map<String, dynamic>>>{};

    for (int i = 0; i < ids.length; i += chunkSize) {
      final List<String> chunk = ids.sublist(
        i,
        (i + chunkSize).clamp(0, ids.length),
      );
      try {
        final QuerySnapshot<Map<String, dynamic>> snap = await _firestore
            .collection('users')
            .where(FieldPath.documentId, whereIn: chunk)
            .get();
        for (final QueryDocumentSnapshot<Map<String, dynamic>> d in snap.docs) {
          freshById[d.id] = d;
        }
      } catch (_) {
        // Ignore refresh errors; optimistic patch remains.
      }
    }

    if (!mounted || freshById.isEmpty) return;
    setState(() {
      _loadedUserDocs = _loadedUserDocs
          .map(
            (QueryDocumentSnapshot<Map<String, dynamic>> d) =>
                freshById[d.id] ?? d,
          )
          .toList(growable: false);

      // Once we have fresh docs, drop any optimistic patches for them.
      for (final String id in freshById.keys) {
        _userDocPatches.remove(id);
      }
    });
  }

  @override
  void dispose() {
    _allUsersScrollController.dispose();
    _userSearchController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _refreshUsers();
  }

  void _toggleMultiSelect() {
    setState(() {
      _multiSelectEnabled = !_multiSelectEnabled;
      _selectedUserIds.clear();
    });
  }

  void _toggleUserSelected(String uid) {
    setState(() {
      if (_selectedUserIds.contains(uid)) {
        _selectedUserIds.remove(uid);
      } else {
        _selectedUserIds.add(uid);
      }
    });
  }

  Future<bool> _confirmBulkAction({
    required String title,
    required String message,
    required String confirmLabel,
  }) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  List<QueryDocumentSnapshot<Map<String, dynamic>>> _selectedDocs() {
    if (_selectedUserIds.isEmpty) return const [];
    final Set<String> ids = _selectedUserIds;
    return _loadedUserDocs
        .where(
          (QueryDocumentSnapshot<Map<String, dynamic>> d) => ids.contains(d.id),
        )
        .toList(growable: false);
  }

  void _startBulkProgress(String label, int total) {
    setState(() {
      _bulkProgress = _BulkProgressInfo(label: label, total: total);
    });
  }

  void _finishBulkProgress() {
    if (!mounted) return;
    setState(() => _bulkProgress = null);
  }

  void _tickBulkProgress({required bool succeeded, String? currentLabel}) {
    if (!mounted) return;
    setState(() {
      final _BulkProgressInfo? p = _bulkProgress;
      if (p == null) return;
      p.processed++;
      if (succeeded) {
        p.success++;
      } else {
        p.failed++;
      }
      p.currentLabel = currentLabel;
    });
  }

  Future<void> _runBulkFixFaceEnrollment() async {
    if (_bulkActionRunning) return;
    final List<QueryDocumentSnapshot<Map<String, dynamic>>> docs =
        _selectedDocs();
    if (docs.isEmpty) return;

    final List<QueryDocumentSnapshot<Map<String, dynamic>>> docsWithEnrollment =
        docs
            .where((QueryDocumentSnapshot<Map<String, dynamic>> doc) {
              final Map<String, dynamic> data = _patchedUserData(doc);
              return _hasLegacyFaceEnrollment(data);
            })
            .toList(growable: false);

    final int totalTargeted = docsWithEnrollment.length;
    if (totalTargeted == 0) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No selected users have face enrollment data.'),
        ),
      );
      return;
    }

    final bool confirmed = await _confirmBulkAction(
      title: 'Fix Face Enrollment',
      message:
          'Are you sure you want to Fix Face Enrollment of $totalTargeted selected user(s)?',
      confirmLabel: 'Fix',
    );
    if (!confirmed) return;

    setState(() => _bulkActionRunning = true);
    _startBulkProgress('Fixing face enrollment', totalTargeted);
    int success = 0;
    int failed = 0;
    final Set<String> touched = <String>{};
    for (final QueryDocumentSnapshot<Map<String, dynamic>> doc
        in docsWithEnrollment) {
      final String name = _resolveDisplayName(doc.data(), doc.id);
      try {
        await _functions.httpsCallable('adminMigrateFaceEmbeds').call(
          <String, dynamic>{'uid': doc.id},
        );
        touched.add(doc.id);
        success++;
        _tickBulkProgress(succeeded: true, currentLabel: name);
      } catch (_) {
        failed++;
        _tickBulkProgress(succeeded: false, currentLabel: name);
      }
    }

    if (!mounted) return;
    setState(() {
      _bulkActionRunning = false;
      _multiSelectEnabled = false;
      _selectedUserIds.clear();
    });
    _finishBulkProgress();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Fix completed. Success: $success, Failed: $failed.'),
      ),
    );

    // Background refresh only for the affected users.
    unawaited(_refreshUsersById(touched));
  }

  Future<void> _runBulkMigrateFaceEnrollmentToVps() async {
    if (_bulkActionRunning) return;
    final List<QueryDocumentSnapshot<Map<String, dynamic>>> docs =
        _selectedDocs();
    if (docs.isEmpty) return;

    final List<QueryDocumentSnapshot<Map<String, dynamic>>> docsWithLegacy =
        docs
            .where((QueryDocumentSnapshot<Map<String, dynamic>> doc) {
              final Map<String, dynamic> data = _patchedUserData(doc);
              return _hasLegacyFaceEnrollment(data);
            })
            .toList(growable: false);

    final int totalTargeted = docsWithLegacy.length;
    if (totalTargeted == 0) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No selected users have legacy Firestore embeddings.'),
        ),
      );
      return;
    }

    final bool confirmed = await _confirmBulkAction(
      title: 'Migrate Face Enrollment to VPS',
      message:
          'This will copy each selected user\'s legacy Firestore embedding to the VPS, then delete the embedding fields from Firestore.\n\nContinue for $totalTargeted user(s)?',
      confirmLabel: 'Migrate',
    );
    if (!confirmed) return;

    setState(() => _bulkActionRunning = true);
    _startBulkProgress('Migrating face enrollment to VPS', totalTargeted);

    int success = 0;
    int failed = 0;
    final Set<String> touched = <String>{};
    const VpsEmbeddingsApiClient vpsClient = VpsEmbeddingsApiClient();

    for (final QueryDocumentSnapshot<Map<String, dynamic>> doc
        in docsWithLegacy) {
      final String name = _resolveDisplayName(doc.data(), doc.id);
      try {
        final Map<String, dynamic> data = _patchedUserData(doc);
        final List<double>? legacy = _extractLegacyEmbedding(data);
        if (legacy == null) {
          failed++;
          _tickBulkProgress(succeeded: false, currentLabel: name);
          continue;
        }

        final List<double> normalized = _l2NormalizeVector(legacy);
        final List<double> payload = normalized.isNotEmpty
            ? normalized
            : legacy;

        await vpsClient.putEmbeddingForUid(
          doc.id,
          embedding: payload,
          model: 'onnx_v1_migrated',
          forceRefreshToken: success == 0,
        );

        // Best-effort cleanup: delete legacy Firestore embedding fields via Admin SDK.
        // VPS is the source of truth; migration should still be considered successful
        // if the VPS write succeeded.
        try {
          await _functions.httpsCallable('adminClearFaceEnrollment').call(
            <String, dynamic>{'uid': doc.id},
          );
        } catch (_) {
          // Ignore; cleanup can be retried later.
        }

        touched.add(doc.id);
        success++;
        _tickBulkProgress(succeeded: true, currentLabel: name);

        if (mounted) {
          setState(() {
            _applyVpsEnrollmentPatch(doc.id, true);
          });
        }
      } catch (_) {
        failed++;
        _tickBulkProgress(succeeded: false, currentLabel: name);
      }
    }

    if (!mounted) return;
    setState(() {
      _bulkActionRunning = false;
      _multiSelectEnabled = false;
      _selectedUserIds.clear();
    });
    _finishBulkProgress();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Migration completed. Success: $success, Failed: $failed.',
        ),
      ),
    );

    unawaited(_refreshUsersById(touched));
  }

  Future<void> _runBulkClearFaceEnrollment() async {
    if (_bulkActionRunning) return;
    final List<QueryDocumentSnapshot<Map<String, dynamic>>> docs =
        _selectedDocs();
    if (docs.isEmpty) return;

    final int totalTargeted = docs.length;

    final bool confirmed = await _confirmBulkAction(
      title: 'Clear Face Enrollment',
      message:
          'Are you sure you want to Clear Face Enrollment of $totalTargeted selected user(s)? This cannot be undone.',
      confirmLabel: 'Clear',
    );
    if (!confirmed) return;

    setState(() => _bulkActionRunning = true);
    _startBulkProgress('Clearing face enrollment', totalTargeted);
    int success = 0;
    int failed = 0;
    final Set<String> cleared = <String>{};
    const VpsEmbeddingsApiClient vpsClient = VpsEmbeddingsApiClient();
    for (final QueryDocumentSnapshot<Map<String, dynamic>> doc in docs) {
      final String name = _resolveDisplayName(doc.data(), doc.id);
      try {
        await vpsClient.deleteEmbeddingForUid(doc.id);

        // Best-effort cleanup: delete any legacy Firestore embedding fields.
        // (This uses Admin SDK and is not blocked by client rules.)
        try {
          await _functions.httpsCallable('adminClearFaceEnrollment').call(
            <String, dynamic>{'uid': doc.id},
          );
        } catch (_) {
          // Ignore; VPS is the source of truth.
        }

        cleared.add(doc.id);
        success++;
        _tickBulkProgress(succeeded: true, currentLabel: name);
      } catch (_) {
        failed++;
        _tickBulkProgress(succeeded: false, currentLabel: name);
      }
    }

    if (!mounted) return;
    setState(() {
      _bulkActionRunning = false;
      _multiSelectEnabled = false;
      _selectedUserIds.clear();
    });
    _finishBulkProgress();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Clear completed. Success: $success, Failed: $failed.'),
      ),
    );

    // Optimistic UI update (no list flicker), then background refresh.
    setState(() {
      for (final String uid in cleared) {
        _applyClearedEnrollmentPatch(uid);
      }
    });
    unawaited(_refreshUsersById(cleared));
  }

  Future<void> _runBulkDeleteUsers() async {
    if (_bulkActionRunning) return;
    final List<QueryDocumentSnapshot<Map<String, dynamic>>> docs =
        _selectedDocs();
    if (docs.isEmpty) return;

    final int total = docs.length;
    final bool confirmed = await _confirmBulkAction(
      title: 'Delete Users',
      message:
          'Are you sure you want to Delete User of $total selected user(s)? This cannot be undone.',
      confirmLabel: 'Delete',
    );
    if (!confirmed) return;

    setState(() => _bulkActionRunning = true);
    _startBulkProgress('Deleting users', total);
    int success = 0;
    int failed = 0;
    final Set<String> deleted = <String>{};
    const VpsEmbeddingsApiClient vpsClient = VpsEmbeddingsApiClient();

    for (final QueryDocumentSnapshot<Map<String, dynamic>> doc in docs) {
      final String name = _resolveDisplayName(doc.data(), doc.id);
      try {
        // Best-effort: also remove face embedding from VPS (source of truth).
        try {
          await vpsClient.deleteEmbeddingForUid(doc.id);
        } catch (_) {
          // Ignore; user deletion should still proceed.
        }
        await _functions.httpsCallable('adminDeleteUser').call(
          <String, dynamic>{'uid': doc.id},
        );
        deleted.add(doc.id);
        success++;
        _tickBulkProgress(succeeded: true, currentLabel: name);
      } catch (_) {
        failed++;
        _tickBulkProgress(succeeded: false, currentLabel: name);
      }
    }

    if (!mounted) return;

    setState(() {
      _bulkActionRunning = false;
      _bulkProgress = null;
      _selectedUserIds.removeAll(deleted);
      _loadedUserDocs = _loadedUserDocs
          .where(
            (QueryDocumentSnapshot<Map<String, dynamic>> d) =>
                !deleted.contains(d.id),
          )
          .toList(growable: false);
      _multiSelectEnabled = false;
    });

    // Re-fetch to keep pagination consistent.
    _refreshUsers();

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Delete completed. Success: $success, Failed: $failed.'),
      ),
    );
  }

  Future<void> _runBulkEditProfiles() async {
    if (_bulkActionRunning) return;
    final List<QueryDocumentSnapshot<Map<String, dynamic>>> docs =
        _selectedDocs();
    if (docs.isEmpty) return;

    final int total = docs.length;
    final bool confirmed = await _confirmBulkAction(
      title: 'Edit Profile',
      message: total == 1
          ? 'Are you sure you want to Edit Profile of the selected user?'
          : 'Are you sure you want to Edit Profile of $total selected user(s)?',
      confirmLabel: 'Continue',
    );
    if (!confirmed) return;

    setState(() => _bulkActionRunning = true);
    _startBulkProgress('Editing profiles', docs.length);
    for (final QueryDocumentSnapshot<Map<String, dynamic>> doc in docs) {
      if (!mounted) break;
      await _editUserProfile(doc);
      final String name = _resolveDisplayName(doc.data(), doc.id);
      _tickBulkProgress(succeeded: true, currentLabel: name);
    }
    if (!mounted) return;
    setState(() {
      _bulkActionRunning = false;
      _bulkProgress = null;
      _multiSelectEnabled = false;
      _selectedUserIds.clear();
    });
  }

  Query<Map<String, dynamic>> _buildUsersPageQuery() {
    Query<Map<String, dynamic>> q = _firestore
        .collection('users')
        .orderBy(FieldPath.documentId);
    if (_lastUserDoc != null) {
      q = q.startAfterDocument(_lastUserDoc!);
    }
    return q.limit(_usersFetchPageSize);
  }

  Future<void> _refreshUsers() async {
    if (_loadingUsers) return;
    setState(() {
      _loadingUsers = true;
      _hasMoreUsers = true;
      _lastUserDoc = null;
      _loadedUserDocs = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
      _selectedUserIds.clear();
      _resetUsersPagination();
    });

    try {
      final QuerySnapshot<Map<String, dynamic>> snap =
          await _buildUsersPageQuery().get();
      final List<QueryDocumentSnapshot<Map<String, dynamic>>> docs = snap.docs;
      setState(() {
        _loadedUserDocs = docs;
        _lastUserDoc = docs.isEmpty ? null : docs.last;
        _hasMoreUsers = docs.length == _usersFetchPageSize;
      });
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to load users: $error')));
    } finally {
      if (mounted) {
        setState(() => _loadingUsers = false);
      }
    }
  }

  Future<void> _loadMoreUsers() async {
    if (_loadingMore || _loadingUsers || !_hasMoreUsers) return;
    setState(() => _loadingMore = true);
    try {
      final QuerySnapshot<Map<String, dynamic>> snap =
          await _buildUsersPageQuery().get();
      final List<QueryDocumentSnapshot<Map<String, dynamic>>> docs = snap.docs;
      setState(() {
        _loadedUserDocs = <QueryDocumentSnapshot<Map<String, dynamic>>>[
          ..._loadedUserDocs,
          ...docs,
        ];
        _lastUserDoc = docs.isEmpty ? _lastUserDoc : docs.last;
        _hasMoreUsers = docs.length == _usersFetchPageSize;
      });
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to load more users: $error')),
      );
    } finally {
      if (mounted) {
        setState(() => _loadingMore = false);
      }
    }
  }

  Query<Map<String, dynamic>> _buildSelectAllQuery({
    required QueryDocumentSnapshot<Map<String, dynamic>>? startAfter,
  }) {
    Query<Map<String, dynamic>> q = _firestore
        .collection('users')
        .orderBy(FieldPath.documentId);

    // Push role filtering into Firestore when possible to avoid scanning the
    // entire users collection.
    if (_showStudents && !_showInstructors) {
      q = q.where('role', isEqualTo: 'student');
    } else if (_showInstructors && !_showStudents) {
      q = q.where('role', isEqualTo: 'instructor');
    }

    if (startAfter != null) {
      q = q.startAfterDocument(startAfter);
    }
    return q.limit(_selectAllFetchPageSize);
  }

  bool _matchesCurrentUserFilters(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final Map<String, dynamic> data = _patchedUserData(doc);
    if (_isAdminAccount(doc.id, data)) return false;

    final String role = ((data['role'] as String?) ?? '').toLowerCase();
    if (role == 'student' && !_showStudents) return false;
    if (role == 'instructor' && !_showInstructors) return false;

    final String q = _searchQuery;
    if (q.isNotEmpty && !_buildSearchHaystack(data, doc.id).contains(q)) {
      return false;
    }

    return true;
  }

  Future<void> _selectAllMatchingUsers() async {
    if (_selectingAll || _bulkActionRunning) return;
    if (!_multiSelectEnabled) return;

    setState(() => _selectingAll = true);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Selecting all matching users...'),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: 2),
      ),
    );

    try {
      final List<QueryDocumentSnapshot<Map<String, dynamic>>> allDocs =
          <QueryDocumentSnapshot<Map<String, dynamic>>>[];

      QueryDocumentSnapshot<Map<String, dynamic>>? cursor;
      while (mounted) {
        if (allDocs.length >= _selectAllHardCap) {
          break;
        }

        final QuerySnapshot<Map<String, dynamic>> snap =
            await _buildSelectAllQuery(startAfter: cursor).get();
        if (snap.docs.isEmpty) {
          break;
        }

        allDocs.addAll(snap.docs);
        cursor = snap.docs.last;
        if (snap.docs.length < _selectAllFetchPageSize) {
          break;
        }
      }

      if (!mounted) return;

      final List<QueryDocumentSnapshot<Map<String, dynamic>>> matching = allDocs
          .where(_matchesCurrentUserFilters)
          .toList(growable: false);

      setState(() {
        // Ensure the loaded list contains everything we just selected so bulk
        // actions operate on the full set (not just the first loaded page).
        _loadedUserDocs = allDocs;
        _lastUserDoc = allDocs.isEmpty ? null : allDocs.last;
        _hasMoreUsers = false;
        _resetUsersPagination();
        _selectedUserIds
          ..clear()
          ..addAll(matching.map((e) => e.id));
      });

      if (allDocs.length >= _selectAllHardCap) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
              'Too many users to select at once. Narrow the filters and try again.',
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text('Select all failed: $error'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _selectingAll = false);
      }
    }
  }

  String _buildSearchHaystack(Map<String, dynamic> data, String docId) {
    final List<String> parts = <String>[
      docId,
      _resolveDisplayName(data, docId),
    ];

    void addValue(dynamic value, {required int depth}) {
      if (value == null) {
        return;
      }
      if (value is String) {
        final String v = value.trim();
        if (v.isNotEmpty) {
          parts.add(v);
        }
        return;
      }
      if (value is num || value is bool) {
        parts.add(value.toString());
        return;
      }
      if (value is Timestamp) {
        parts.add(value.toDate().toIso8601String());
        return;
      }
      if (depth <= 0) {
        return;
      }
      if (value is Map) {
        for (final dynamic v in value.values) {
          addValue(v, depth: depth - 1);
        }
        return;
      }
      if (value is Iterable) {
        for (final dynamic v in value) {
          addValue(v, depth: depth - 1);
        }
        return;
      }
    }

    // Collect all primitive-ish values to make search resilient to legacy schemas.
    for (final dynamic v in data.values) {
      addValue(v, depth: 2);
    }

    return parts.join(' ').toLowerCase();
  }

  Future<void> _approveInstructor(String uid) async {
    try {
      await _functions.httpsCallable('adminApproveInstructor').call(
        <String, dynamic>{'uid': uid},
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Instructor approved.')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to approve: $error')));
    }
  }

  Future<void> _migrateFaceEnrollmentFormat(String uid) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Fix face enrollment format?'),
        content: const Text(
          'This will convert legacy face embedding storage to the current format. '
          'It does not change the embedding values, only how they are stored.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Fix'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final result = await _functions
          .httpsCallable('adminMigrateFaceEmbeds')
          .call(<String, dynamic>{'uid': uid});
      final data = result.data;
      final bool migrated =
          data is Map &&
          (data['migrated'] == true || data['migrated'] == 'true');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            migrated
                ? 'Face enrollment format updated.'
                : 'No migration needed for this user.',
          ),
        ),
      );

      // Background refresh only for this user (keeps pagination intact).
      unawaited(_refreshUsersById(<String>[uid]));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to migrate enrollment: $error')),
      );
    }
  }

  Future<void> _clearFaceEnrollment(String uid) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Clear face enrollment?'),
        content: const Text(
          'This will remove the stored face embedding for this account. The student will need to re-enroll to use face recognition again.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      const VpsEmbeddingsApiClient vpsClient = VpsEmbeddingsApiClient();
      await vpsClient.deleteEmbeddingForUid(uid);

      // Best-effort cleanup: delete any legacy Firestore embedding fields.
      try {
        await _functions.httpsCallable('adminClearFaceEnrollment').call(
          <String, dynamic>{'uid': uid},
        );
      } catch (_) {
        // Ignore; VPS is the source of truth.
      }
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Face enrollment cleared.')));

      // Optimistic UI update (no list flicker), then background refresh.
      setState(() {
        _applyClearedEnrollmentPatch(uid);
      });
      unawaited(_refreshUsersById(<String>[uid]));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to clear enrollment: $error')),
      );
    }
  }

  Future<void> _migrateFaceEnrollmentToVps(String uid) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Migrate face enrollment to VPS?'),
        content: const Text(
          'This will copy the legacy Firestore embedding for this account to the VPS, then delete the embedding fields from Firestore.\n\nUse this only as a one-time migration for existing records.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Migrate'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final DocumentSnapshot<Map<String, dynamic>> snap = await _firestore
          .collection('users')
          .doc(uid)
          .get(const GetOptions(source: Source.server));
      final Map<String, dynamic> data = snap.data() ?? <String, dynamic>{};
      final List<double>? legacy = _extractLegacyEmbedding(data);
      if (legacy == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No legacy Firestore embedding found.')),
        );
        return;
      }

      final List<double> normalized = _l2NormalizeVector(legacy);
      final List<double> payload = normalized.isNotEmpty ? normalized : legacy;

      const VpsEmbeddingsApiClient vpsClient = VpsEmbeddingsApiClient();
      await vpsClient.putEmbeddingForUid(
        uid,
        embedding: payload,
        model: 'onnx_v1_migrated',
        forceRefreshToken: true,
      );

      // Best-effort cleanup: delete legacy Firestore embedding fields via Admin SDK.
      try {
        await _functions.httpsCallable('adminClearFaceEnrollment').call(
          <String, dynamic>{'uid': uid},
        );
      } catch (_) {
        // Ignore; VPS is the source of truth.
      }

      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Migration completed.')));

      setState(() {
        _applyVpsEnrollmentPatch(uid, true);
      });
      unawaited(_refreshUsersById(<String>[uid]));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to migrate: $error')));
    }
  }

  Future<void> _deleteUser(String uid, String label) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Delete user?'),
        content: Text(
          'This will permanently delete the account ($label), remove their profile, delete their VPS face enrollment, and attempt to remove their attendance references. This cannot be undone.',
        ),
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
    if (confirmed != true) return;

    try {
      // Best-effort: also remove face embedding from VPS (source of truth).
      try {
        const VpsEmbeddingsApiClient vpsClient = VpsEmbeddingsApiClient();
        await vpsClient.deleteEmbeddingForUid(uid);
      } catch (_) {
        // Ignore; user deletion should still proceed.
      }
      await _functions.httpsCallable('adminDeleteUser').call(<String, dynamic>{
        'uid': uid,
      });
      if (!mounted) return;

      setState(() {
        _loadedUserDocs = _loadedUserDocs
            .where(
              (QueryDocumentSnapshot<Map<String, dynamic>> d) => d.id != uid,
            )
            .toList(growable: false);
      });

      // Re-fetch to keep pagination consistent.
      _refreshUsers();

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('User deleted.')));
    } catch (error) {
      if (!mounted) return;

      String message = error.toString();
      if (error is FirebaseFunctionsException) {
        final String details = error.details?.toString() ?? '';
        message = [
          '[${error.code}]',
          if ((error.message ?? '').trim().isNotEmpty) error.message!.trim(),
          if (details.trim().isNotEmpty) details.trim(),
        ].join(' ');
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to delete: $message')));
    }
  }

  Future<void> _editUserProfile(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) async {
    final Map<String, dynamic>? data = doc.data();
    if (data == null) return;
    final String role = (data['role'] as String?)?.toLowerCase() ?? '';

    final TextEditingController nameController = TextEditingController(
      text:
          (data['displayName'] as String?) ??
          (data['Full Name'] as String?) ??
          '',
    );
    final TextEditingController departmentController = TextEditingController(
      text: (data['Department'] as String?) ?? '',
    );
    final TextEditingController sectionController = TextEditingController(
      text: (data['section'] as String?) ?? '',
    );
    final TextEditingController studentIdController = TextEditingController(
      text: (data['Student ID'] as String?) ?? '',
    );

    bool saving = false;
    final bool? saved = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (BuildContext context, void Function(void Function()) set) {
            return AlertDialog(
              title: const Text('Edit user'),
              content: SizedBox(
                width: 520,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    TextField(
                      controller: nameController,
                      decoration: const InputDecoration(labelText: 'Full name'),
                    ),
                    if (role == 'instructor')
                      TextField(
                        controller: departmentController,
                        decoration: const InputDecoration(
                          labelText: 'Department',
                        ),
                      ),
                    if (role == 'student') ...<Widget>[
                      TextField(
                        controller: studentIdController,
                        decoration: const InputDecoration(
                          labelText: 'Student ID',
                        ),
                      ),
                      TextField(
                        controller: sectionController,
                        decoration: const InputDecoration(labelText: 'Section'),
                      ),
                    ],
                  ],
                ),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: saving
                      ? null
                      : () => Navigator.of(context).pop(false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: saving
                      ? null
                      : () async {
                          set(() => saving = true);
                          try {
                            final Map<String, Object?> update =
                                <String, Object?>{
                                  'displayName': nameController.text.trim(),
                                  'Full Name': nameController.text.trim(),
                                };
                            if (role == 'instructor') {
                              update['Department'] = departmentController.text
                                  .trim();
                            }
                            if (role == 'student') {
                              final String newStudentId = studentIdController
                                  .text
                                  .trim();
                              if (newStudentId.isEmpty) {
                                throw FirebaseException(
                                  plugin: 'cloud_firestore',
                                  code: 'invalid-student-id',
                                  message: 'Student ID is required.',
                                );
                              }
                              final String? oldStudentId =
                                  (data['studentId'] as String?) ??
                                  (data['Student ID'] as String?);
                              await UserRoleService.adminSwapStudentId(
                                uid: doc.id,
                                newStudentId: newStudentId,
                                oldStudentId: oldStudentId,
                                otherUpdates: <String, Object?>{
                                  ...update,
                                  'section': sectionController.text.trim(),
                                },
                              );
                              if (context.mounted) {
                                Navigator.of(context).pop(true);
                              }
                              return;
                            }
                            await _firestore
                                .collection('users')
                                .doc(doc.id)
                                .set(update, SetOptions(merge: true));
                            if (context.mounted) {
                              Navigator.of(context).pop(true);
                            }
                          } catch (error) {
                            set(() => saving = false);
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('Save failed: $error')),
                              );
                            }
                          }
                        },
                  child: saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );

    nameController.dispose();
    departmentController.dispose();
    sectionController.dispose();
    studentIdController.dispose();

    if (saved == true && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Profile updated.')));
    }
  }

  String _resolveDisplayName(Map<String, dynamic>? data, String fallbackId) {
    if (data == null) {
      return fallbackId;
    }

    const List<String> nameCandidates = <String>[
      'displayName',
      'display_name',
      'Full Name',
      'fullName',
      'FullName',
      'full_name',
      'fullname',
      'name',
      'studentName',
      'student_name',
    ];
    for (final String key in nameCandidates) {
      final String? raw = (data[key] as String?)?.trim();
      if (raw != null && raw.isNotEmpty) {
        return raw;
      }
    }

    // Handle legacy/variant field names like "Full name", "full name", etc.
    for (final MapEntry<String, dynamic> entry in data.entries) {
      final String key = entry.key.toLowerCase();
      final dynamic value = entry.value;
      if (value is! String) continue;
      final String raw = value.trim();
      if (raw.isEmpty) continue;
      if (key.contains('name')) {
        return raw;
      }
    }

    const List<String> emailCandidates = <String>['Email', 'email'];
    for (final String key in emailCandidates) {
      final String? raw = (data[key] as String?)?.trim();
      if (raw != null && raw.isNotEmpty) {
        return raw;
      }
    }

    for (final MapEntry<String, dynamic> entry in data.entries) {
      final String key = entry.key.toLowerCase();
      final dynamic value = entry.value;
      if (value is! String) continue;
      final String raw = value.trim();
      if (raw.isEmpty) continue;
      if (key.contains('email')) {
        return raw;
      }
    }

    return fallbackId;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  'Instructor approvals',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  stream: _firestore
                      .collection('users')
                      .where('role', isEqualTo: 'instructor')
                      .snapshots(),
                  builder:
                      (
                        BuildContext context,
                        AsyncSnapshot<QuerySnapshot<Map<String, dynamic>>>
                        snapshot,
                      ) {
                        if (snapshot.connectionState ==
                            ConnectionState.waiting) {
                          return const Padding(
                            padding: EdgeInsets.symmetric(vertical: 8),
                            child: LinearProgressIndicator(),
                          );
                        }
                        if (snapshot.hasError) {
                          return Text(
                            'Failed to load approvals: ${snapshot.error}',
                          );
                        }
                        final List<QueryDocumentSnapshot<Map<String, dynamic>>>
                        docs =
                            (snapshot.data?.docs ??
                                    <
                                      QueryDocumentSnapshot<
                                        Map<String, dynamic>
                                      >
                                    >[])
                                .where((
                                  QueryDocumentSnapshot<Map<String, dynamic>>
                                  doc,
                                ) {
                                  final Map<String, dynamic> data = doc.data();
                                  return data['approved'] != true;
                                })
                                .toList(growable: false);
                        if (docs.isEmpty) {
                          return const Text('No pending instructor accounts.');
                        }
                        return Column(
                          children: docs.map((
                            QueryDocumentSnapshot<Map<String, dynamic>> doc,
                          ) {
                            final Map<String, dynamic> data = doc.data();
                            final String name = _resolveDisplayName(
                              data,
                              doc.id,
                            );
                            final String email =
                                (data['Email'] as String?) ?? '';
                            return ListTile(
                              contentPadding: EdgeInsets.zero,
                              title: Text(name),
                              subtitle: email.isEmpty ? null : Text(email),
                              trailing: FilledButton(
                                onPressed: () => _approveInstructor(doc.id),
                                child: const Text('Approve'),
                              ),
                            );
                          }).toList(),
                        );
                      },
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    final bool isNarrow = constraints.maxWidth < 520;
                    final List<QueryDocumentSnapshot<Map<String, dynamic>>>
                    visibleDocs = _filteredUserDocs();
                    final bool allVisibleSelected =
                        visibleDocs.isNotEmpty &&
                        visibleDocs.every(
                          (QueryDocumentSnapshot<Map<String, dynamic>> d) =>
                              _selectedUserIds.contains(d.id),
                        );

                    final Widget refreshButton = isNarrow
                        ? IconButton(
                            tooltip: 'Refresh',
                            onPressed: _loadingUsers ? null : _refreshUsers,
                            icon: const Icon(Icons.refresh),
                          )
                        : TextButton.icon(
                            onPressed: _loadingUsers ? null : _refreshUsers,
                            icon: const Icon(Icons.refresh, size: 18),
                            label: const Text('Refresh'),
                          );

                    final String multiLabel = _multiSelectEnabled
                        ? 'Cancel'
                        : 'Select Multiple';
                    final IconData multiIcon = _multiSelectEnabled
                        ? Icons.close
                        : Icons.checklist_rtl;
                    final Widget multiSelectButton = isNarrow
                        ? IconButton(
                            tooltip: multiLabel,
                            onPressed: _bulkActionRunning
                                ? null
                                : _toggleMultiSelect,
                            icon: Icon(multiIcon),
                          )
                        : TextButton.icon(
                            onPressed: _bulkActionRunning
                                ? null
                                : _toggleMultiSelect,
                            icon: Icon(multiIcon, size: 18),
                            label: Text(multiLabel),
                          );

                    final bool canSelectAll =
                        _multiSelectEnabled &&
                        !_bulkActionRunning &&
                        visibleDocs.isNotEmpty &&
                        !_selectingAll;
                    final String selectAllLabel = allVisibleSelected
                        ? 'Clear selection'
                        : 'Select all';
                    final IconData selectAllIcon = allVisibleSelected
                        ? Icons.clear_all
                        : Icons.select_all;
                    final Widget selectAllButton = isNarrow
                        ? IconButton(
                            tooltip: selectAllLabel,
                            onPressed: canSelectAll
                                ? () {
                                    if (allVisibleSelected) {
                                      setState(() => _selectedUserIds.clear());
                                      return;
                                    }
                                    _selectAllMatchingUsers();
                                  }
                                : null,
                            icon: Icon(selectAllIcon),
                          )
                        : TextButton.icon(
                            onPressed: canSelectAll
                                ? () {
                                    if (allVisibleSelected) {
                                      setState(() => _selectedUserIds.clear());
                                      return;
                                    }
                                    _selectAllMatchingUsers();
                                  }
                                : null,
                            icon: Icon(selectAllIcon, size: 18),
                            label: Text(selectAllLabel),
                          );

                    Widget? optionsWidget;
                    if (_multiSelectEnabled) {
                      final bool disabled =
                          _selectedUserIds.isEmpty || _bulkActionRunning;
                      if (disabled) {
                        optionsWidget = isNarrow
                            ? IconButton(
                                tooltip: 'Options',
                                onPressed: null,
                                icon: const Icon(Icons.tune),
                              )
                            : TextButton.icon(
                                onPressed: null,
                                icon: const Icon(Icons.tune, size: 18),
                                label: const Text('Options'),
                              );
                      } else {
                        final ThemeData theme = Theme.of(context);
                        optionsWidget = PopupMenuButton<_BulkUserAction>(
                          onSelected: (_BulkUserAction action) async {
                            switch (action) {
                              case _BulkUserAction.editProfile:
                                await _runBulkEditProfiles();
                              case _BulkUserAction.fixFaceEnrollment:
                                await _runBulkFixFaceEnrollment();
                              case _BulkUserAction.migrateFaceEnrollmentToVps:
                                await _runBulkMigrateFaceEnrollmentToVps();
                              case _BulkUserAction.clearFaceEnrollment:
                                await _runBulkClearFaceEnrollment();
                              case _BulkUserAction.deleteUser:
                                await _runBulkDeleteUsers();
                            }
                          },
                          itemBuilder: (BuildContext context) {
                            return const <PopupMenuEntry<_BulkUserAction>>[
                              PopupMenuItem<_BulkUserAction>(
                                value: _BulkUserAction.editProfile,
                                child: Text('Edit profile'),
                              ),
                              PopupMenuItem<_BulkUserAction>(
                                value: _BulkUserAction.fixFaceEnrollment,
                                child: Text('Fix Face Enrollment'),
                              ),
                              PopupMenuItem<_BulkUserAction>(
                                value:
                                    _BulkUserAction.migrateFaceEnrollmentToVps,
                                child: Text('Migrate Face Enrollment to VPS'),
                              ),
                              PopupMenuItem<_BulkUserAction>(
                                value: _BulkUserAction.clearFaceEnrollment,
                                child: Text('Clear Face Enrollment'),
                              ),
                              PopupMenuDivider(),
                              PopupMenuItem<_BulkUserAction>(
                                value: _BulkUserAction.deleteUser,
                                child: Text('Delete User'),
                              ),
                            ];
                          },
                          icon: isNarrow
                              ? Icon(
                                  Icons.tune,
                                  color: theme.colorScheme.primary,
                                )
                              : null,
                          child: isNarrow
                              ? null
                              : IgnorePointer(
                                  ignoring: true,
                                  child: TextButton.icon(
                                    onPressed: () {},
                                    icon: Icon(
                                      Icons.tune,
                                      size: 18,
                                      color: theme.colorScheme.primary,
                                    ),
                                    label: Text(
                                      'Options',
                                      style: TextStyle(
                                        color: theme.colorScheme.primary,
                                      ),
                                    ),
                                  ),
                                ),
                        );
                      }
                    }

                    final List<Widget> actions = <Widget>[
                      if (_multiSelectEnabled)
                        Chip(
                          label: Text('Selected: ${_selectedUserIds.length}'),
                        ),
                      if (_multiSelectEnabled) selectAllButton,
                      refreshButton,
                      multiSelectButton,
                      if (optionsWidget != null) optionsWidget,
                    ];

                    return Row(
                      children: <Widget>[
                        const Expanded(
                          child: Text(
                            'All users',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              alignment: WrapAlignment.end,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: actions,
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
                _buildBulkProgressBanner(),
                const SizedBox(height: 8),
                TextField(
                  controller: _userSearchController,
                  onChanged: (String value) {
                    setState(() {
                      _searchQuery = value.trim().toLowerCase();
                      _resetUsersPagination();
                    });
                  },
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search),
                    hintText: 'Search users',
                    suffixIcon: _searchQuery.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Clear search',
                            onPressed: () {
                              _userSearchController.clear();
                              setState(() {
                                _searchQuery = '';
                                _resetUsersPagination();
                              });
                            },
                            icon: const Icon(Icons.clear),
                          ),
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    FilterChip(
                      label: const Text('Students'),
                      selected: _showStudents,
                      onSelected: (bool value) {
                        setState(() {
                          _showStudents = value;
                          _resetUsersPagination();
                        });
                      },
                    ),
                    FilterChip(
                      label: const Text('Instructors'),
                      selected: _showInstructors,
                      onSelected: (bool value) {
                        setState(() {
                          _showInstructors = value;
                          _resetUsersPagination();
                        });
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Builder(
                  builder: (BuildContext context) {
                    if (_loadingUsers) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: LinearProgressIndicator(),
                      );
                    }

                    final List<QueryDocumentSnapshot<Map<String, dynamic>>>
                    filteredDocs = _filteredUserDocs();

                    if (!_showStudents && !_showInstructors) {
                      return const Text(
                        'Select Students and/or Instructors to filter the list.',
                      );
                    }
                    if (filteredDocs.isEmpty) {
                      return const Text('No users found.');
                    }

                    final int totalRows = filteredDocs.length;
                    final int totalPages = _totalPagesFor(totalRows);
                    final int pageIndex = _usersPageIndex.clamp(
                      0,
                      totalPages - 1,
                    );
                    final int start = pageIndex * _usersRowsPerPage;
                    final int end = (start + _usersRowsPerPage).clamp(
                      0,
                      totalRows,
                    );
                    final List<QueryDocumentSnapshot<Map<String, dynamic>>>
                    pageDocs = filteredDocs.sublist(start, end);

                    final bool canGoPrev = pageIndex > 0;
                    final bool canGoNext =
                        (pageIndex < totalPages - 1) || _hasMoreUsers;

                    final double listHeight =
                        (MediaQuery.sizeOf(context).height * 0.50)
                            .clamp(280.0, 520.0)
                            .toDouble();

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Wrap(
                          spacing: 12,
                          runSpacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: <Widget>[
                            SizedBox(
                              width: 210,
                              child: DropdownButtonFormField<int>(
                                initialValue: _usersRowsPerPage,
                                decoration: const InputDecoration(
                                  labelText: 'Rows per page',
                                ),
                                items: _usersRowsPerPageOptions
                                    .map(
                                      (int value) => DropdownMenuItem<int>(
                                        value: value,
                                        child: Text(value.toString()),
                                      ),
                                    )
                                    .toList(growable: false),
                                onChanged: (int? value) {
                                  if (value == null) return;
                                  setState(() {
                                    _usersRowsPerPage = value;
                                    _resetUsersPagination();
                                  });
                                },
                              ),
                            ),
                            if (_loadingMore)
                              const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            Text('Page ${pageIndex + 1} / $totalPages'),
                            IconButton(
                              tooltip: 'Previous page',
                              onPressed: canGoPrev ? _goToPrevUsersPage : null,
                              icon: const Icon(Icons.chevron_left),
                            ),
                            IconButton(
                              tooltip: 'Next page',
                              onPressed: canGoNext ? _goToNextUsersPage : null,
                              icon: const Icon(Icons.chevron_right),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        SizedBox(
                          height: listHeight,
                          child: Scrollbar(
                            controller: _allUsersScrollController,
                            thumbVisibility: true,
                            child: ListView.separated(
                              controller: _allUsersScrollController,
                              itemCount: pageDocs.length,
                              separatorBuilder: (_, __) =>
                                  const Divider(height: 1),
                              itemBuilder: (BuildContext context, int index) {
                                final QueryDocumentSnapshot<
                                  Map<String, dynamic>
                                >
                                doc = pageDocs[index];
                                final Map<String, dynamic> data =
                                    _patchedUserData(doc);
                                final String name = _resolveDisplayName(
                                  data,
                                  doc.id,
                                );
                                final String role =
                                    (data['role'] as String?) ?? '';
                                final String normalizedRole = role
                                    .trim()
                                    .toLowerCase();
                                if (normalizedRole == 'student' ||
                                    normalizedRole.contains('student')) {
                                  unawaited(_ensureVpsEnrollmentCached(doc.id));
                                }

                                final bool hasEnrollment = _hasFaceEnrollment(
                                  doc.id,
                                  data,
                                );
                                final bool hasLegacyEnrollment =
                                    _hasLegacyFaceEnrollment(data);
                                final bool approved = data['approved'] == true;
                                final bool selected = _selectedUserIds.contains(
                                  doc.id,
                                );

                                final ThemeData theme = Theme.of(context);
                                final Widget menuIcon = hasEnrollment
                                    ? Stack(
                                        clipBehavior: Clip.none,
                                        children: <Widget>[
                                          const Icon(Icons.more_vert),
                                          Positioned(
                                            right: -2,
                                            top: -2,
                                            child: Container(
                                              width: 14,
                                              height: 14,
                                              decoration: BoxDecoration(
                                                color:
                                                    theme.colorScheme.tertiary,
                                                shape: BoxShape.circle,
                                                border: Border.all(
                                                  color:
                                                      theme.colorScheme.surface,
                                                  width: 1.5,
                                                ),
                                              ),
                                              child: Icon(
                                                Icons.face,
                                                size: 10,
                                                color: theme
                                                    .colorScheme
                                                    .onTertiary,
                                              ),
                                            ),
                                          ),
                                        ],
                                      )
                                    : const Icon(Icons.more_vert);

                                return ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  onTap: _multiSelectEnabled
                                      ? () => _toggleUserSelected(doc.id)
                                      : null,
                                  leading: _multiSelectEnabled
                                      ? Checkbox(
                                          value: selected,
                                          onChanged: (bool? value) {
                                            _toggleUserSelected(doc.id);
                                          },
                                        )
                                      : null,
                                  title: Text(name),
                                  subtitle: Text(
                                    role.isEmpty
                                        ? 'No role'
                                        : (role.toLowerCase() == 'instructor'
                                              ? (approved
                                                    ? 'Instructor (approved)'
                                                    : 'Instructor (pending)')
                                              : role),
                                  ),
                                  trailing: _multiSelectEnabled
                                      ? (selected
                                            ? const Icon(Icons.check_circle)
                                            : const Icon(
                                                Icons.radio_button_unchecked,
                                              ))
                                      : PopupMenuButton<String>(
                                          icon: menuIcon,
                                          onSelected: (String action) {
                                            switch (action) {
                                              case 'edit':
                                                _editUserProfile(doc);
                                                break;
                                              case 'approve':
                                                _approveInstructor(doc.id);
                                                break;
                                              case 'migrateEnrollment':
                                                _migrateFaceEnrollmentFormat(
                                                  doc.id,
                                                );
                                                break;
                                              case 'migrateToVps':
                                                _migrateFaceEnrollmentToVps(
                                                  doc.id,
                                                );
                                                break;
                                              case 'clearEnrollment':
                                                _clearFaceEnrollment(doc.id);
                                                break;
                                              case 'delete':
                                                _deleteUser(doc.id, name);
                                                break;
                                            }
                                          },
                                          itemBuilder: (BuildContext context) {
                                            return <PopupMenuEntry<String>>[
                                              const PopupMenuItem<String>(
                                                value: 'edit',
                                                child: Text('Edit profile'),
                                              ),
                                              if (role.toLowerCase() ==
                                                      'instructor' &&
                                                  !approved)
                                                const PopupMenuItem<String>(
                                                  value: 'approve',
                                                  child: Text(
                                                    'Approve instructor',
                                                  ),
                                                ),
                                              if (hasLegacyEnrollment)
                                                const PopupMenuItem<String>(
                                                  value: 'migrateEnrollment',
                                                  child: Text(
                                                    'Fix face enrollment format',
                                                  ),
                                                ),
                                              if (hasLegacyEnrollment)
                                                const PopupMenuItem<String>(
                                                  value: 'migrateToVps',
                                                  child: Text(
                                                    'Migrate face enrollment to VPS',
                                                  ),
                                                ),
                                              const PopupMenuItem<String>(
                                                value: 'clearEnrollment',
                                                child: Text(
                                                  'Clear face enrollment',
                                                ),
                                              ),
                                              const PopupMenuDivider(),
                                              const PopupMenuItem<String>(
                                                value: 'delete',
                                                child: Text('Delete user'),
                                              ),
                                            ];
                                          },
                                        ),
                                );
                              },
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _AttendanceSessionsPanel extends StatefulWidget {
  const _AttendanceSessionsPanel();

  @override
  State<_AttendanceSessionsPanel> createState() =>
      _AttendanceSessionsPanelState();
}

class _AttendanceSessionsPanelState extends State<_AttendanceSessionsPanel> {
  static const int _pageSize = 50;
  static const int _bulkChunkSize = 30;
  static const int _bulkScanPageSize = 200;

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();

  bool _loading = false;
  bool _loadingMore = false;
  bool _hasMore = true;
  QueryDocumentSnapshot<Map<String, dynamic>>? _lastDoc;
  List<QueryDocumentSnapshot<Map<String, dynamic>>> _docs =
      <QueryDocumentSnapshot<Map<String, dynamic>>>[];

  bool _multiSelect = false;
  final Set<String> _selectedIds = <String>{};
  bool _bulkDeleting = false;

  String _search = '';
  String _statusFilter = 'all';
  String _dateFilter = 'last7';
  DateTimeRange? _customRange;

  DateTime _dayKey(DateTime dt) => DateTime(dt.year, dt.month, dt.day);

  (DateTime start, DateTime endExclusive)? _selectedStartedAtWindow() {
    final DateTime now = DateTime.now();
    final DateTime today = _dayKey(now);

    switch (_dateFilter) {
      case 'all':
        return null;
      case 'today':
        return (today, today.add(const Duration(days: 1)));
      case 'last7':
        return (
          today.subtract(const Duration(days: 6)),
          today.add(const Duration(days: 1)),
        );
      case 'last30':
        return (
          today.subtract(const Duration(days: 29)),
          today.add(const Duration(days: 1)),
        );
      case 'custom':
        final DateTimeRange? range = _customRange;
        if (range == null) return null;
        final DateTime start = _dayKey(range.start);
        final DateTime endDay = _dayKey(range.end);
        return (start, endDay.add(const Duration(days: 1)));
    }
    return null;
  }

  String _dateFilterLabel() {
    switch (_dateFilter) {
      case 'all':
        return 'All time';
      case 'today':
        return 'Today';
      case 'last7':
        return 'Last 7 days';
      case 'last30':
        return 'Last 30 days';
      case 'custom':
        final DateTimeRange? range = _customRange;
        if (range == null) return 'Custom';
        String two(int n) => n.toString().padLeft(2, '0');
        String fmt(DateTime d) => '${d.year}-${two(d.month)}-${two(d.day)}';
        return '${fmt(range.start)} → ${fmt(range.end)}';
    }
    return 'Last 7 days';
  }

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Query<Map<String, dynamic>> _buildQuery() {
    Query<Map<String, dynamic>> q = _firestore
        .collection('attendanceSessions')
        .orderBy('startedAt', descending: true);

    final (DateTime start, DateTime endExclusive)? window =
        _selectedStartedAtWindow();
    if (window != null) {
      q = q
          .where(
            'startedAt',
            isGreaterThanOrEqualTo: Timestamp.fromDate(window.$1),
          )
          .where('startedAt', isLessThan: Timestamp.fromDate(window.$2));
    }
    if (_lastDoc != null) {
      q = q.startAfterDocument(_lastDoc!);
    }
    return q.limit(_pageSize);
  }

  Future<void> _pickCustomRange() async {
    final DateTime now = DateTime.now();
    final DateTime first = DateTime(now.year - 2, 1, 1);
    final DateTime last = DateTime(now.year + 1, 12, 31);
    final DateTimeRange initial =
        _customRange ??
        DateTimeRange(
          start: _dayKey(now.subtract(const Duration(days: 6))),
          end: _dayKey(now),
        );
    final DateTimeRange? picked = await showDateRangePicker(
      context: context,
      firstDate: first,
      lastDate: last,
      initialDateRange: initial,
    );
    if (picked == null || !mounted) return;
    setState(() {
      _customRange = picked;
      _dateFilter = 'custom';
    });
    await _refresh();
  }

  Future<void> _refresh() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _loadingMore = false;
      _hasMore = true;
      _lastDoc = null;
      _docs = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
      _selectedIds.clear();
    });

    try {
      final QuerySnapshot<Map<String, dynamic>> snap = await _buildQuery().get(
        const GetOptions(source: Source.server),
      );
      final List<QueryDocumentSnapshot<Map<String, dynamic>>> docs = snap.docs;
      if (!mounted) return;
      setState(() {
        _docs = docs;
        _lastDoc = docs.isEmpty ? null : docs.last;
        _hasMore = docs.length == _pageSize;
      });
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to load sessions: $error')),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _toggleMultiSelect(bool enabled) {
    setState(() {
      _multiSelect = enabled;
      if (!enabled) {
        _selectedIds.clear();
      }
    });
  }

  void _toggleSelected(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
    });
  }

  bool _matchesClientFilters(QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final Map<String, dynamic> data = doc.data();
    if (_statusFilter != 'all') {
      final String st = (data['status']?.toString().toLowerCase() ?? '');
      if (st != _statusFilter) return false;
    }
    final String q = _search;
    if (q.isNotEmpty && !_buildHaystack(data, doc.id).contains(q)) {
      return false;
    }
    return true;
  }

  Future<({int deletedCount, int failedCount})> _deleteIdsInChunks(
    List<String> ids, {
    void Function(int processed, int deleted, int failed)? onProgress,
  }) async {
    int processed = 0;
    int deleted = 0;
    int failed = 0;

    for (int i = 0; i < ids.length; i += _bulkChunkSize) {
      final List<String> chunk = ids.sublist(
        i,
        (i + _bulkChunkSize).clamp(0, ids.length),
      );

      try {
        final HttpsCallableResult<dynamic> res = await FirebaseFunctions
            .instance
            .httpsCallable('adminBulkDeleteAttendanceSessions')
            .call(<String, dynamic>{'sessionIds': chunk});
        final dynamic data = res.data;
        final int deletedCount = (data is Map && data['deletedCount'] is num)
            ? (data['deletedCount'] as num).toInt()
            : 0;
        final int failedCount = (data is Map && data['failedCount'] is num)
            ? (data['failedCount'] as num).toInt()
            : 0;
        deleted += deletedCount;
        failed += failedCount;
      } catch (_) {
        // If the callable failed, count whole chunk as failed.
        failed += chunk.length;
      }

      processed += chunk.length;
      onProgress?.call(processed, deleted, failed);
    }

    return (deletedCount: deleted, failedCount: failed);
  }

  Future<void> _confirmAndDeleteSelected(List<String> ids) async {
    if (_bulkDeleting || ids.isEmpty) return;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Delete selected sessions?'),
        content: Text(
          'This will permanently delete ${ids.length} selected session(s), including recorded students/scans. This cannot be undone.',
        ),
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
    if (confirmed != true || !mounted) return;

    setState(() => _bulkDeleting = true);
    try {
      int processed = 0;
      int deleted = 0;
      int failed = 0;

      final ({int deletedCount, int failedCount}) result =
          (await showDialog<({int deletedCount, int failedCount})>(
            context: context,
            barrierDismissible: false,
            builder: (BuildContext dialogContext) {
              bool started = false;
              return StatefulBuilder(
                builder:
                    (BuildContext context, void Function(void Function()) set) {
                      if (!started) {
                        started = true;
                        unawaited(() async {
                          final ({int deletedCount, int failedCount}) res =
                              await _deleteIdsInChunks(
                                ids,
                                onProgress: (int p, int d, int f) {
                                  if (!dialogContext.mounted) return;
                                  set(() {
                                    processed = p;
                                    deleted = d;
                                    failed = f;
                                  });
                                },
                              );
                          if (!dialogContext.mounted) return;
                          Navigator.of(dialogContext).pop(res);
                        }());
                      }

                      return AlertDialog(
                        title: const Text('Deleting…'),
                        content: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            const LinearProgressIndicator(),
                            const SizedBox(height: 12),
                            Text('Processed: $processed / ${ids.length}'),
                            Text('Deleted: $deleted'),
                            if (failed > 0) Text('Failed: $failed'),
                          ],
                        ),
                      );
                    },
              );
            },
          )) ??
          (deletedCount: 0, failedCount: ids.length);

      if (!mounted) return;
      setState(() {
        _docs = _docs
            .where(
              (QueryDocumentSnapshot<Map<String, dynamic>> d) =>
                  !ids.contains(d.id),
            )
            .toList(growable: false);
        _selectedIds.removeAll(ids);
        _multiSelect = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Delete done. Deleted: ${result.deletedCount}, Failed: ${result.failedCount}.',
          ),
        ),
      );
      unawaited(_refresh());
    } finally {
      if (mounted) setState(() => _bulkDeleting = false);
    }
  }

  Query<Map<String, dynamic>> _buildBulkScanQuery({
    QueryDocumentSnapshot<Map<String, dynamic>>? startAfter,
  }) {
    Query<Map<String, dynamic>> q = _firestore
        .collection('attendanceSessions')
        .orderBy('startedAt', descending: true);

    final (DateTime start, DateTime endExclusive)? window =
        _selectedStartedAtWindow();
    if (window != null) {
      q = q
          .where(
            'startedAt',
            isGreaterThanOrEqualTo: Timestamp.fromDate(window.$1),
          )
          .where('startedAt', isLessThan: Timestamp.fromDate(window.$2));
    }

    if (startAfter != null) {
      q = q.startAfterDocument(startAfter);
    }
    return q.limit(_bulkScanPageSize);
  }

  Future<void> _confirmAndDeleteAllMatching() async {
    if (_bulkDeleting) return;
    final String scope =
        (_dateFilter == 'all' && _statusFilter == 'all' && _search.isEmpty)
        ? 'ALL sessions'
        : 'all sessions matching your current filters';

    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Delete many sessions?'),
        content: Text(
          'This will permanently delete $scope, including recorded students/scans. This cannot be undone.\n\nThis may take a while.',
        ),
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
    if (confirmed != true || !mounted) return;

    setState(() => _bulkDeleting = true);

    try {
      int scanned = 0;
      int matched = 0;
      int deleted = 0;
      int failed = 0;

      final ({int scanned, int matched, int deleted, int failed}) result =
          (await showDialog<
            ({int scanned, int matched, int deleted, int failed})
          >(
            context: context,
            barrierDismissible: false,
            builder: (BuildContext dialogContext) {
              bool started = false;
              return StatefulBuilder(
                builder:
                    (BuildContext context, void Function(void Function()) set) {
                      if (!started) {
                        started = true;
                        unawaited(() async {
                          final List<String> buffer = <String>[];
                          QueryDocumentSnapshot<Map<String, dynamic>>? last;

                          while (true) {
                            final QuerySnapshot<Map<String, dynamic>> snap =
                                await _buildBulkScanQuery(
                                  startAfter: last,
                                ).get(const GetOptions(source: Source.server));
                            if (snap.docs.isEmpty) break;

                            for (final QueryDocumentSnapshot<
                                  Map<String, dynamic>
                                >
                                doc
                                in snap.docs) {
                              scanned++;
                              if (_matchesClientFilters(doc)) {
                                buffer.add(doc.id);
                                matched++;
                                if (buffer.length >= _bulkChunkSize) {
                                  final ({int deletedCount, int failedCount})
                                  res = await _deleteIdsInChunks(
                                    List<String>.from(buffer),
                                  );
                                  deleted += res.deletedCount;
                                  failed += res.failedCount;
                                  buffer.clear();
                                  if (!dialogContext.mounted) return;
                                  set(() {});
                                }
                              }
                              if (!dialogContext.mounted) return;
                              if (scanned % 50 == 0) set(() {});
                            }

                            last = snap.docs.last;
                            if (!dialogContext.mounted) return;
                            set(() {});
                            if (snap.size < _bulkScanPageSize) break;
                          }

                          if (buffer.isNotEmpty) {
                            final ({int deletedCount, int failedCount}) res =
                                await _deleteIdsInChunks(
                                  List<String>.from(buffer),
                                );
                            deleted += res.deletedCount;
                            failed += res.failedCount;
                            buffer.clear();
                          }

                          if (!dialogContext.mounted) return;
                          Navigator.of(dialogContext).pop((
                            scanned: scanned,
                            matched: matched,
                            deleted: deleted,
                            failed: failed,
                          ));
                        }());
                      }

                      return AlertDialog(
                        title: const Text('Deleting…'),
                        content: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            const LinearProgressIndicator(),
                            const SizedBox(height: 12),
                            Text('Scanned: $scanned'),
                            Text('Matched: $matched'),
                            Text('Deleted: $deleted'),
                            if (failed > 0) Text('Failed: $failed'),
                          ],
                        ),
                      );
                    },
              );
            },
          )) ??
          (scanned: 0, matched: 0, deleted: 0, failed: 0);

      if (!mounted) return;
      setState(() {
        _multiSelect = false;
        _selectedIds.clear();
      });
      unawaited(_refresh());
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Delete done. Deleted: ${result.deleted}, Failed: ${result.failed}.',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _bulkDeleting = false);
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _loading || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      final QuerySnapshot<Map<String, dynamic>> snap = await _buildQuery().get(
        const GetOptions(source: Source.server),
      );
      final List<QueryDocumentSnapshot<Map<String, dynamic>>> docs = snap.docs;
      if (!mounted) return;
      setState(() {
        _docs = <QueryDocumentSnapshot<Map<String, dynamic>>>[
          ..._docs,
          ...docs,
        ];
        _lastDoc = docs.isEmpty ? _lastDoc : docs.last;
        _hasMore = docs.length == _pageSize;
      });
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to load more sessions: $error')),
      );
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  String _formatTimestamp(Object? value) {
    if (value is Timestamp) {
      final DateTime dt = value.toDate();
      String two(int n) => n.toString().padLeft(2, '0');
      return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
    }
    return '';
  }

  String _buildHaystack(Map<String, dynamic> data, String id) {
    final List<String> parts = <String>[id];
    void add(dynamic v, {required int depth}) {
      if (v == null) return;
      if (v is String) {
        final String t = v.trim();
        if (t.isNotEmpty) parts.add(t);
        return;
      }
      if (v is num || v is bool) {
        parts.add(v.toString());
        return;
      }
      if (v is Timestamp) {
        parts.add(v.toDate().toIso8601String());
        return;
      }
      if (depth <= 0) return;
      if (v is Map) {
        for (final dynamic vv in v.values) {
          add(vv, depth: depth - 1);
        }
        return;
      }
      if (v is Iterable) {
        for (final dynamic vv in v) {
          add(vv, depth: depth - 1);
        }
        return;
      }
    }

    for (final dynamic v in data.values) {
      add(v, depth: 2);
    }
    return parts.join(' ').toLowerCase();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    final List<QueryDocumentSnapshot<Map<String, dynamic>>> filtered = _docs
        .where((QueryDocumentSnapshot<Map<String, dynamic>> doc) {
          final Map<String, dynamic> data = doc.data();
          if (_statusFilter == 'all') return true;
          return (data['status']?.toString().toLowerCase() ?? '') ==
              _statusFilter;
        })
        .where((QueryDocumentSnapshot<Map<String, dynamic>> doc) {
          final String q = _search;
          if (q.isEmpty) return true;
          return _buildHaystack(doc.data(), doc.id).contains(q);
        })
        .toList(growable: false);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    'Attendance Sessions',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Refresh',
                  onPressed: _loading ? null : _refresh,
                  icon: const Icon(Icons.refresh),
                ),
                const SizedBox(width: 4),
                if (!_multiSelect)
                  OutlinedButton.icon(
                    onPressed: _bulkDeleting
                        ? null
                        : () => _toggleMultiSelect(true),
                    icon: const Icon(Icons.checklist, size: 18),
                    label: const Text('Select'),
                  )
                else ...<Widget>[
                  OutlinedButton(
                    onPressed: _bulkDeleting
                        ? null
                        : () {
                            setState(() {
                              for (final doc in filtered) {
                                _selectedIds.add(doc.id);
                              }
                            });
                          },
                    child: const Text('Select all shown'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: (_bulkDeleting || _selectedIds.isEmpty)
                        ? null
                        : () => _confirmAndDeleteSelected(
                            _selectedIds.toList(growable: false),
                          ),
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: Text('Delete selected (${_selectedIds.length})'),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: _bulkDeleting
                        ? null
                        : () => _toggleMultiSelect(false),
                    child: const Text('Cancel'),
                  ),
                ],
                PopupMenuButton<String>(
                  tooltip: 'More actions',
                  onSelected: (String action) {
                    switch (action) {
                      case 'deleteAll':
                        _confirmAndDeleteAllMatching();
                        break;
                      case 'clearSelection':
                        setState(() => _selectedIds.clear());
                        break;
                    }
                  },
                  itemBuilder: (BuildContext context) {
                    final bool deleteAllEnabled =
                        !_bulkDeleting && !_loading && !_loadingMore;
                    final String deleteAllLabel =
                        (_dateFilter == 'all' &&
                            _statusFilter == 'all' &&
                            _search.isEmpty)
                        ? 'Delete ALL sessions'
                        : 'Delete all matching filters';
                    return <PopupMenuEntry<String>>[
                      PopupMenuItem<String>(
                        value: 'deleteAll',
                        enabled: deleteAllEnabled,
                        child: ListTile(
                          dense: true,
                          leading: const Icon(Icons.delete_forever_outlined),
                          title: Text(deleteAllLabel),
                          subtitle: const Text('Includes students and scans'),
                        ),
                      ),
                      if (_multiSelect) const PopupMenuDivider(),
                      if (_multiSelect)
                        PopupMenuItem<String>(
                          value: 'clearSelection',
                          enabled: !_bulkDeleting && _selectedIds.isNotEmpty,
                          child: const ListTile(
                            dense: true,
                            leading: Icon(Icons.clear_all),
                            title: Text('Clear selection'),
                          ),
                        ),
                    ];
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                SizedBox(
                  width: 360,
                  child: TextField(
                    controller: _searchController,
                    onChanged: (String value) {
                      setState(() => _search = value.trim().toLowerCase());
                    },
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search),
                      hintText:
                          'Search sessions (class, subject, instructor…) ',
                      suffixIcon: _search.isEmpty
                          ? null
                          : IconButton(
                              tooltip: 'Clear',
                              onPressed: () {
                                _searchController.clear();
                                setState(() => _search = '');
                              },
                              icon: const Icon(Icons.clear),
                            ),
                    ),
                  ),
                ),
                DropdownButton<String>(
                  value: _statusFilter,
                  onChanged: (String? value) {
                    if (value == null) return;
                    setState(() => _statusFilter = value);
                  },
                  items: const <DropdownMenuItem<String>>[
                    DropdownMenuItem(value: 'all', child: Text('All statuses')),
                    DropdownMenuItem(value: 'active', child: Text('Active')),
                    DropdownMenuItem(value: 'paused', child: Text('Paused')),
                    DropdownMenuItem(value: 'ended', child: Text('Ended')),
                  ],
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: <Widget>[
                    ChoiceChip(
                      label: const Text('All'),
                      selected: _dateFilter == 'all',
                      onSelected: (bool selected) async {
                        if (!selected) return;
                        setState(() => _dateFilter = 'all');
                        await _refresh();
                      },
                    ),
                    ChoiceChip(
                      label: const Text('Today'),
                      selected: _dateFilter == 'today',
                      onSelected: (bool selected) async {
                        if (!selected) return;
                        setState(() => _dateFilter = 'today');
                        await _refresh();
                      },
                    ),
                    ChoiceChip(
                      label: const Text('Last 7'),
                      selected: _dateFilter == 'last7',
                      onSelected: (bool selected) async {
                        if (!selected) return;
                        setState(() => _dateFilter = 'last7');
                        await _refresh();
                      },
                    ),
                    ChoiceChip(
                      label: const Text('Last 30'),
                      selected: _dateFilter == 'last30',
                      onSelected: (bool selected) async {
                        if (!selected) return;
                        setState(() => _dateFilter = 'last30');
                        await _refresh();
                      },
                    ),
                    OutlinedButton.icon(
                      onPressed: _pickCustomRange,
                      icon: const Icon(Icons.date_range, size: 18),
                      label: Text(_dateFilterLabel()),
                    ),
                  ],
                ),
                Text(
                  _loading
                      ? 'Loading…'
                      : 'Showing ${filtered.length} of ${_docs.length}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_loading)
              const LinearProgressIndicator()
            else if (filtered.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('No sessions found.'),
              )
            else
              SizedBox(
                height: (MediaQuery.sizeOf(context).height * 0.55)
                    .clamp(320.0, 680.0)
                    .toDouble(),
                child: Scrollbar(
                  controller: _scrollController,
                  thumbVisibility: true,
                  child: ListView.separated(
                    controller: _scrollController,
                    itemCount: filtered.length + 1,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (BuildContext context, int index) {
                      if (index >= filtered.length) {
                        if (_loadingMore) {
                          return const Padding(
                            padding: EdgeInsets.symmetric(vertical: 12),
                            child: Center(
                              child: SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                            ),
                          );
                        }
                        if (!_hasMore) {
                          return const Padding(
                            padding: EdgeInsets.symmetric(vertical: 12),
                            child: Center(child: Text('End of list.')),
                          );
                        }
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Center(
                            child: OutlinedButton.icon(
                              onPressed: _loadMore,
                              icon: const Icon(Icons.expand_more),
                              label: const Text('Load more'),
                            ),
                          ),
                        );
                      }

                      final QueryDocumentSnapshot<Map<String, dynamic>> doc =
                          filtered[index];
                      final Map<String, dynamic> data = doc.data();
                      final String subjectCode =
                          (data['subjectCode'] as String?) ?? '';
                      final String subjectName =
                          (data['subjectName'] as String?) ?? '';
                      final String section = (data['section'] as String?) ?? '';
                      final String classId = (data['classId'] as String?) ?? '';
                      final String status =
                          (data['status']?.toString().toLowerCase() ?? '');
                      final String startedAt = _formatTimestamp(
                        data['startedAt'] ?? data['createdAt'],
                      );
                      final String instructorEmail =
                          (data['instructorEmail'] as String?) ?? '';
                      final String location =
                          (data['location'] as String?) ?? '';

                      final String title = [
                        if (subjectCode.isNotEmpty) subjectCode,
                        subjectName,
                      ].where((String s) => s.trim().isNotEmpty).join(' • ');

                      final List<String> chips = <String>[
                        if (status.isNotEmpty) status,
                        if (section.isNotEmpty) 'section $section',
                        if (location.isNotEmpty) location,
                      ];

                      return ListTile(
                        onLongPress: () {
                          if (!_multiSelect) {
                            _toggleMultiSelect(true);
                          }
                          _toggleSelected(doc.id);
                        },
                        onTap: _multiSelect
                            ? () => _toggleSelected(doc.id)
                            : () async {
                                final bool? deleted = await showDialog<bool>(
                                  context: context,
                                  builder: (_) =>
                                      _AttendanceSessionDetailsDialog(
                                        sessionId: doc.id,
                                        sessionRef: doc.reference,
                                      ),
                                );
                                if (deleted == true && mounted) {
                                  await _refresh();
                                }
                              },
                        leading: _multiSelect
                            ? Checkbox(
                                value: _selectedIds.contains(doc.id),
                                onChanged: (_) => _toggleSelected(doc.id),
                              )
                            : null,
                        title: Text(title.isEmpty ? '(No subject)' : title),
                        subtitle: Text(
                          [
                            if (classId.isNotEmpty) 'Class: $classId',
                            if (startedAt.isNotEmpty) 'Started: $startedAt',
                            if (instructorEmail.isNotEmpty)
                              'Instructor: $instructorEmail',
                            if (chips.isNotEmpty) chips.join(' • '),
                          ].join('\n'),
                        ),
                        isThreeLine: true,
                        trailing: _multiSelect
                            ? (_selectedIds.contains(doc.id)
                                  ? const Icon(Icons.check_circle)
                                  : const Icon(Icons.radio_button_unchecked))
                            : const Icon(Icons.chevron_right),
                      );
                    },
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _AttendanceSessionDetailsDialog extends StatelessWidget {
  const _AttendanceSessionDetailsDialog({
    required this.sessionId,
    required this.sessionRef,
  });

  final String sessionId;
  final DocumentReference<Map<String, dynamic>> sessionRef;

  Future<void> _deleteSession(BuildContext context) async {
    final NavigatorState navigator = Navigator.of(context);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);

    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Delete this session?'),
        content: const Text(
          'This will permanently delete the session and its recorded students/scans. This cannot be undone.',
        ),
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
    if (confirmed != true) return;

    if (!context.mounted) return;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: <Widget>[
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 12),
            Text('Deleting session…'),
          ],
        ),
      ),
    );

    try {
      final result = await FirebaseFunctions.instance
          .httpsCallable('adminDeleteAttendanceSession')
          .call(<String, dynamic>{'sessionId': sessionId});

      final dynamic data = result.data;
      final bool deleted =
          data is Map && (data['deleted'] == true || data['deleted'] == 'true');

      if (context.mounted) {
        navigator.pop();
        navigator.pop(true);
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              deleted ? 'Session deleted.' : 'Session already deleted.',
            ),
          ),
        );
      }
    } catch (error) {
      if (context.mounted) {
        navigator.pop();

        String message = error.toString();
        if (error is FirebaseFunctionsException) {
          final String details = error.details?.toString() ?? '';
          message = [
            '[${error.code}]',
            if ((error.message ?? '').trim().isNotEmpty) error.message!.trim(),
            if (details.trim().isNotEmpty) details.trim(),
          ].join(' ');
        }
        messenger.showSnackBar(
          SnackBar(content: Text('Delete failed: $message')),
        );
      }
    }
  }

  String _fmtTs(Timestamp? ts, {bool showSeconds = false}) {
    if (ts == null) return '';
    final DateTime dt = ts.toDate();
    String two(int n) => n.toString().padLeft(2, '0');
    final String base =
        '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
    if (!showSeconds) return base;
    return '$base:${two(dt.second)}';
  }

  Object? _jsonFriendly(Object? value, {required int depth}) {
    if (value == null) return null;
    if (value is String || value is num || value is bool) return value;
    if (value is Timestamp) return value.toDate().toIso8601String();
    if (value is GeoPoint) {
      return <String, Object?>{'lat': value.latitude, 'lng': value.longitude};
    }
    if (value is DocumentReference) return value.path;
    if (depth <= 0) return value.toString();
    if (value is Map) {
      final Map<String, Object?> out = <String, Object?>{};
      value.forEach((dynamic k, dynamic v) {
        out[k.toString()] = _jsonFriendly(v, depth: depth - 1);
      });
      return out;
    }
    if (value is Iterable) {
      return value
          .map((Object? v) => _jsonFriendly(v, depth: depth - 1))
          .toList(growable: false);
    }
    return value.toString();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 920, maxHeight: 720),
        child: DefaultTabController(
          length: 3,
          child: Column(
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                        stream: sessionRef.snapshots(),
                        builder:
                            (
                              BuildContext context,
                              AsyncSnapshot<
                                DocumentSnapshot<Map<String, dynamic>>
                              >
                              snapshot,
                            ) {
                              final Map<String, dynamic>? data = snapshot.data
                                  ?.data();
                              final Timestamp? startedAtTs =
                                  (data?['startedAt'] as Timestamp?) ??
                                  (data?['createdAt'] as Timestamp?);

                              String fmt(Timestamp? ts) {
                                if (ts == null) return '';
                                final DateTime dt = ts.toDate();
                                String two(int n) =>
                                    n.toString().padLeft(2, '0');
                                return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
                              }

                              final String startedLabel = fmt(startedAtTs);
                              final String title = startedLabel.isEmpty
                                  ? 'Session'
                                  : 'Session started: $startedLabel';

                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(
                                    title,
                                    style: theme.textTheme.titleMedium
                                        ?.copyWith(fontWeight: FontWeight.w700),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  Text(
                                    'ID: $sessionId',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              );
                            },
                      ),
                    ),
                    PopupMenuButton<String>(
                      tooltip: 'Actions',
                      onSelected: (String v) {
                        switch (v) {
                          case 'delete':
                            _deleteSession(context);
                            break;
                        }
                      },
                      itemBuilder: (BuildContext context) {
                        return <PopupMenuEntry<String>>[
                          const PopupMenuItem<String>(
                            value: 'delete',
                            child: ListTile(
                              dense: true,
                              leading: Icon(Icons.delete_outline),
                              title: Text('Delete session'),
                            ),
                          ),
                        ];
                      },
                    ),
                    IconButton(
                      tooltip: 'Close',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              const TabBar(
                tabs: <Widget>[
                  Tab(text: 'Overview'),
                  Tab(text: 'Students'),
                  Tab(text: 'Scans'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: <Widget>[
                    _buildSummaryTab(theme),
                    _buildAttendeesTab(theme),
                    _buildCapturesTab(theme),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSummaryTab(ThemeData theme) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: sessionRef.snapshots(),
      builder:
          (
            BuildContext context,
            AsyncSnapshot<DocumentSnapshot<Map<String, dynamic>>> snapshot,
          ) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Center(child: Text('Failed to load: ${snapshot.error}'));
            }
            final Map<String, dynamic>? data = snapshot.data?.data();
            if (data == null) {
              return const Center(child: Text('Session not found.'));
            }

            final Map<String, Object?> jsonSafe =
                (_jsonFriendly(data, depth: 5) as Map?)
                    ?.cast<String, Object?>() ??
                <String, Object?>{};
            final String pretty = const JsonEncoder.withIndent(
              '  ',
            ).convert(jsonSafe);

            String s(String key) => (data[key] as String?) ?? '';
            final String subject = [
              s('subjectCode'),
              s('subjectName'),
            ].where((String v) => v.trim().isNotEmpty).join(' • ');
            final String status = (data['status']?.toString() ?? '').trim();
            final String instructorEmail =
                (data['instructorEmail'] as String?) ?? '';
            final String startedAt = _fmtTs(data['startedAt'] as Timestamp?);
            final String endedAt = _fmtTs(data['endedAt'] as Timestamp?);

            return Padding(
              padding: const EdgeInsets.all(16),
              child: ListView(
                children: <Widget>[
                  Text(
                    subject.isEmpty ? '(No subject)' : subject,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: <Widget>[
                      _kvChip('Status', status.isEmpty ? 'unknown' : status),
                      _kvChip(
                        'Class',
                        s('classId').isEmpty ? '-' : s('classId'),
                      ),
                      if (s('section').trim().isNotEmpty)
                        _kvChip('Section', s('section')),
                      if (s('location').trim().isNotEmpty)
                        _kvChip('Location', s('location')),
                      if (instructorEmail.trim().isNotEmpty)
                        _kvChip('Instructor', instructorEmail),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (startedAt.isNotEmpty)
                    Text(
                      'Start time: $startedAt',
                      style: theme.textTheme.bodyMedium,
                    ),
                  if (endedAt.isNotEmpty)
                    Text(
                      'End time:   $endedAt',
                      style: theme.textTheme.bodyMedium,
                    ),
                  const SizedBox(height: 16),
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: Text(
                      'Advanced (technical)',
                      style: theme.textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    subtitle: const Text('For troubleshooting only'),
                    children: <Widget>[
                      const SizedBox(height: 8),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: SelectableText(
                          pretty,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
                ],
              ),
            );
          },
    );
  }

  static Widget _kvChip(String label, String value) {
    return Chip(label: Text('$label: $value'));
  }

  Widget _buildAttendeesTab(ThemeData theme) {
    final Query<Map<String, dynamic>> q = sessionRef
        .collection('attendees')
        .orderBy('lastCapturedAt', descending: true)
        .limit(500);

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: q.snapshots(),
      builder:
          (
            BuildContext context,
            AsyncSnapshot<QuerySnapshot<Map<String, dynamic>>> snapshot,
          ) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Center(
                child: Text('Failed to load attendees: ${snapshot.error}'),
              );
            }
            final List<QueryDocumentSnapshot<Map<String, dynamic>>> docs =
                snapshot.data?.docs ?? const [];
            if (docs.isEmpty) {
              return const Center(
                child: Text('No students have been marked yet.'),
              );
            }

            return ListView.separated(
              padding: const EdgeInsets.all(8),
              itemCount: docs.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (BuildContext context, int index) {
                final Map<String, dynamic> data = docs[index].data();
                final String name =
                    (data['displayName'] as String?) ?? docs[index].id;
                final String status = (data['status'] as String?) ?? '';
                final double? confidence = (data['confidence'] is num)
                    ? (data['confidence'] as num).toDouble()
                    : null;
                final Timestamp? first = data['firstCapturedAt'] as Timestamp?;
                final Timestamp? last = data['lastCapturedAt'] as Timestamp?;

                String fmtTs(Timestamp? ts) {
                  if (ts == null) return '';
                  final DateTime dt = ts.toDate();
                  String two(int n) => n.toString().padLeft(2, '0');
                  return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
                }

                final String subtitle = <String>[
                  if (status.isNotEmpty) 'Marked as: $status',
                  if (confidence != null)
                    'Confidence: ${(confidence * 100).toStringAsFixed(0)}%',
                  if (first != null) 'First: ${fmtTs(first)}',
                  if (last != null) 'Last: ${fmtTs(last)}',
                ].join(' • ');

                return ListTile(
                  title: Text(name),
                  subtitle: subtitle.isEmpty ? null : Text(subtitle),
                  dense: true,
                );
              },
            );
          },
    );
  }

  Widget _buildCapturesTab(ThemeData theme) {
    final Query<Map<String, dynamic>> q = sessionRef
        .collection('captures')
        .orderBy('capturedAt', descending: true)
        .limit(200);

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: q.snapshots(),
      builder:
          (
            BuildContext context,
            AsyncSnapshot<QuerySnapshot<Map<String, dynamic>>> snapshot,
          ) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Center(
                child: Text('Failed to load captures: ${snapshot.error}'),
              );
            }
            final List<QueryDocumentSnapshot<Map<String, dynamic>>> docs =
                snapshot.data?.docs ?? const [];
            if (docs.isEmpty) {
              return const Center(child: Text('No scans recorded yet.'));
            }

            String fmtTs(Timestamp? ts) {
              if (ts == null) return '';
              final DateTime dt = ts.toDate();
              String two(int n) => n.toString().padLeft(2, '0');
              return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
            }

            return ListView.separated(
              padding: const EdgeInsets.all(8),
              itemCount: docs.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (BuildContext context, int index) {
                final Map<String, dynamic> data = docs[index].data();
                final String name =
                    (data['matchDisplayName'] as String?) ??
                    (data['matchUserId'] as String?) ??
                    'Unknown';
                final String status =
                    (data['attendanceStatus'] as String?) ?? '';
                final double? confidence = (data['confidence'] is num)
                    ? (data['confidence'] as num).toDouble()
                    : null;
                final Timestamp? capturedAt = data['capturedAt'] as Timestamp?;

                final List<String> bits = <String>[
                  if (status.isNotEmpty) 'Status: $status',
                  if (confidence != null)
                    'Conf: ${(confidence * 100).toStringAsFixed(0)}%',
                  if (capturedAt != null) fmtTs(capturedAt),
                ];

                return ListTile(
                  title: Text(name),
                  subtitle: bits.isEmpty ? null : Text(bits.join(' • ')),
                  dense: true,
                );
              },
            );
          },
    );
  }
}
