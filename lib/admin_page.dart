import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import 'reports/generate_report_page.dart';
import 'reports/attendance_report_template_meta.dart';
import 'services/excuse_request_service.dart';
import 'services/user_role_service.dart';

enum _AdminSection { overview, users, departments, subjects, classes, excuses }

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
      _AdminSection.excuses,
      'Excuse Requests',
      Icons.report_problem_outlined,
    ),
  ];

  Future<void> _openPdfFromAttachment(Map<String, dynamic>? attachment) async {
    if (attachment == null) return;
    final String path = (attachment['path'] as String?) ?? '';
    if (path.isEmpty) return;
    try {
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
        const Text(
          'Excuse requests',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 12),
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

                            return ListTile(
                              contentPadding: EdgeInsets.zero,
                              title: Text(
                                '$studentName${section.isEmpty ? '' : ' • $section'}',
                              ),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(dateLabel),
                                  if (reason.isNotEmpty)
                                    Text(
                                      reason,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                ],
                              ),
                              trailing: Wrap(
                                spacing: 8,
                                children: <Widget>[
                                  Chip(label: Text(status.toUpperCase())),
                                  IconButton(
                                    tooltip: 'Open PDF',
                                    onPressed: attachment == null
                                        ? null
                                        : () => _openPdfFromAttachment(
                                            attachment,
                                          ),
                                    icon: const Icon(
                                      Icons.picture_as_pdf_outlined,
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: 'Disapprove',
                                    onPressed:
                                        (!isPending || _isApprovingExcuse)
                                        ? null
                                        : () =>
                                              _disapproveExcuseRequest(doc.id),
                                    icon: const Icon(Icons.cancel_outlined),
                                  ),
                                  IconButton(
                                    tooltip: 'Approve',
                                    onPressed:
                                        (!isPending || _isApprovingExcuse)
                                        ? null
                                        : () => _approveExcuseRequest(doc.id),
                                    icon: _isApprovingExcuse && isPending
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
                                  ),
                                  IconButton(
                                    tooltip: 'Delete',
                                    onPressed: _isDeletingExcuse
                                        ? null
                                        : () => _deleteExcuseRequest(doc.id),
                                    icon: _isDeletingExcuse
                                        ? const SizedBox(
                                            width: 18,
                                            height: 18,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                          )
                                        : const Icon(Icons.delete_outline),
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
    final List<_AdminAction> actions = <_AdminAction>[
      _AdminAction(
        'Review Attendance Reports',
        Icons.insights_outlined,
        onTap: () =>
            Navigator.of(context).pushNamed(GenerateReportPage.routeName),
      ),
      _AdminAction(
        'Review Excuse Requests',
        Icons.report_problem_outlined,
        onTap: () => setState(() => _selectedSection = _AdminSection.excuses),
      ),
      _AdminAction(
        'Manage Departments',
        Icons.account_tree_outlined,
        onTap: () =>
            setState(() => _selectedSection = _AdminSection.departments),
      ),
      _AdminAction(
        'Approve Instructor Accounts',
        Icons.verified_user_outlined,
        onTap: () => setState(() => _selectedSection = _AdminSection.users),
      ),
      _AdminAction(
        'Edit Report Header Details',
        Icons.description_outlined,
        onTap: () async {
          await showDialog<void>(
            context: context,
            builder: (BuildContext context) =>
                const _AttendanceReportTemplateMetaDialog(),
          );
        },
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Admin Dashboard'),
        actions: <Widget>[
          TextButton.icon(
            onPressed: () async {
              try {
                await FirebaseAuth.instance.signOut();
              } catch (_) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Failed to sign out. Please try again.'),
                    ),
                  );
                }
                return;
              }

              if (context.mounted) {
                Navigator.of(context).pushNamedAndRemoveUntil(
                  '/login',
                  (Route<dynamic> route) => false,
                );
              }
            },
            icon: const Icon(Icons.logout, size: 18),
            label: const Text('Sign out'),
          ),
        ],
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
                _buildSectionNavigation(),
                const SizedBox(height: 24),
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
                      actions: actions,
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

  Widget _buildSectionNavigation() {
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: _navItems.map((_SectionNavItem item) {
        final bool isSelected = item.section == _selectedSection;
        return ChoiceChip(
          label: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(item.icon, size: 18),
              const SizedBox(width: 6),
              Text(item.label),
            ],
          ),
          selected: isSelected,
          onSelected: (_) {
            if (isSelected) return;
            setState(() => _selectedSection = item.section);
          },
        );
      }).toList(),
    );
  }

  Widget _buildSectionContent({
    required _AdminSection section,
    required ThemeData theme,
    required bool isWide,
    required List<_AdminAction> actions,
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
                  final _AdminOverviewStats data =
                      snapshot.data ?? const _AdminOverviewStats();
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
                    Text(
                      'System overview',
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 24),
                    statsContent,
                    const SizedBox(height: 32),
                    Text(
                      'Quick actions',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    ...actions.map(
                      (_AdminAction action) => _AdminActionTile(action: action),
                    ),
                  ],
                );
              },
        );
      case _AdminSection.departments:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const <Widget>[
            Text(
              'Department maintenance',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
            ),
            SizedBox(height: 12),
            _DepartmentMaintenancePanel(),
          ],
        );
      case _AdminSection.users:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const <Widget>[
            Text(
              'User management',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
            ),
            SizedBox(height: 12),
            _UserManagementPanel(),
          ],
        );
      case _AdminSection.subjects:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const <Widget>[
            Text(
              'Subject catalog',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
            ),
            SizedBox(height: 12),
            _SubjectCatalogPanel(),
          ],
        );
      case _AdminSection.classes:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const <Widget>[
            Text(
              'Class maintenance',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
            ),
            SizedBox(height: 12),
            _ClassMaintenancePanel(),
          ],
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
    final Future<int> instructorsFuture = _countDocuments(
      usersCollection.where('role', isEqualTo: 'instructor'),
    );
    final Future<int> studentsFuture = _countDocuments(
      usersCollection.where('role', isEqualTo: 'student'),
    );
    final Future<int> alertsFuture = _countDocuments(
      firestore.collection('alerts'),
    );
    final List<int> counts = await Future.wait(<Future<int>>[
      instructorsFuture,
      studentsFuture,
      alertsFuture,
    ]);
    return _AdminOverviewStats(
      instructors: counts[0],
      students: counts[1],
      alerts: counts[2],
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
  final TextEditingController _effectiveDateController = TextEditingController();
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to save: $error')),
      );
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
  });

  final int instructors;
  final int students;
  final int alerts;
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
            Row(
              children: <Widget>[
                const Expanded(
                  child: Text('Manage departments available across programs.'),
                ),
                FilledButton.icon(
                  onPressed: () => _openDepartmentDialog(),
                  icon: const Icon(Icons.add),
                  label: const Text('Add department'),
                ),
              ],
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
                        return ListTile(
                          title: Text(
                            data['name'] as String? ?? 'Unnamed department',
                          ),
                          subtitle: abbr.isEmpty
                              ? null
                              : Text('Abbreviation: $abbr'),
                          trailing: Wrap(
                            spacing: 4,
                            children: <Widget>[
                              IconButton(
                                icon: const Icon(Icons.edit_outlined),
                                tooltip: 'Edit',
                                onPressed: () => _openDepartmentDialog(doc),
                              ),
                              IconButton(
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
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextFormField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: 'Department name'),
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
                initialValue: _selectedDepartmentId,
                decoration: const InputDecoration(labelText: 'Department'),
                items: widget.departments
                    .map(
                      (_DepartmentOption department) =>
                          DropdownMenuItem<String>(
                            value: department.id,
                            child: Text(department.name),
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
                    return ListView.separated(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: docs.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (BuildContext context, int index) {
                        final QueryDocumentSnapshot<Map<String, dynamic>> doc =
                            docs[index];
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
                        final List<dynamic> schedules =
                            (data['schedules'] as List<dynamic>? ??
                            <dynamic>[]);
                        final Iterable<String>
                        scheduleSummaries = schedules.map((dynamic entry) {
                          final Map<String, dynamic> schedule =
                              entry as Map<String, dynamic>;
                          final String type =
                              (schedule['type'] as String?)?.toUpperCase() ??
                              '';
                          final String day =
                              (schedule['day'] as String?) ?? 'Unspecified';
                          final Map<String, dynamic>? start =
                              schedule['startTime'] as Map<String, dynamic>?;
                          final Map<String, dynamic>? end =
                              schedule['endTime'] as Map<String, dynamic>?;
                          final String formattedStart = start == null
                              ? '--:--'
                              : '${start['hour']}:${(start['minute'] as int?)?.toString().padLeft(2, '0') ?? '00'} ${start['period'] ?? ''}';
                          final String formattedEnd = end == null
                              ? '--:--'
                              : '${end['hour']}:${(end['minute'] as int?)?.toString().padLeft(2, '0') ?? '00'} ${end['period'] ?? ''}';
                          return '$type • $day • $formattedStart - $formattedEnd';
                        });
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text('$subjectCode • $section'),
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
                          trailing: IconButton(
                            icon: const Icon(Icons.edit_note_outlined),
                            onPressed: () => _openClassDialog(existing: doc),
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

class _AdminAction {
  const _AdminAction(this.label, this.icon, {this.onTap});

  final String label;
  final IconData icon;
  final VoidCallback? onTap;
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

class _AdminActionTile extends StatelessWidget {
  const _AdminActionTile({required this.action});

  final _AdminAction action;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ListTile(
        leading: Icon(action.icon),
        title: Text(action.label),
        trailing: const Icon(Icons.chevron_right),
        onTap: action.onTap,
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

  static const int _usersPageSize = 50;
  bool _loadingUsers = false;
  bool _loadingMore = false;
  bool _hasMoreUsers = true;
  QueryDocumentSnapshot<Map<String, dynamic>>? _lastUserDoc;
  List<QueryDocumentSnapshot<Map<String, dynamic>>> _loadedUserDocs =
      <QueryDocumentSnapshot<Map<String, dynamic>>>[];

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

  Query<Map<String, dynamic>> _buildUsersPageQuery() {
    Query<Map<String, dynamic>> q = _firestore
        .collection('users')
        .orderBy(FieldPath.documentId);
    if (_lastUserDoc != null) {
      q = q.startAfterDocument(_lastUserDoc!);
    }
    return q.limit(_usersPageSize);
  }

  Future<void> _refreshUsers() async {
    if (_loadingUsers) return;
    setState(() {
      _loadingUsers = true;
      _hasMoreUsers = true;
      _lastUserDoc = null;
      _loadedUserDocs = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
    });

    try {
      final QuerySnapshot<Map<String, dynamic>> snap =
          await _buildUsersPageQuery().get();
      final List<QueryDocumentSnapshot<Map<String, dynamic>>> docs = snap.docs;
      setState(() {
        _loadedUserDocs = docs;
        _lastUserDoc = docs.isEmpty ? null : docs.last;
        _hasMoreUsers = docs.length == _usersPageSize;
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
        _hasMoreUsers = docs.length == _usersPageSize;
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
      await _functions.httpsCallable('adminClearFaceEnrollment').call(
        <String, dynamic>{'uid': uid},
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Face enrollment cleared.')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to clear enrollment: $error')),
      );
    }
  }

  Future<void> _deleteUser(String uid, String label) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Delete user?'),
        content: Text(
          'This will permanently delete the account ($label), remove their profile, and attempt to remove their attendance references. This cannot be undone.',
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
                Row(
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
                    TextButton.icon(
                      onPressed: _loadingUsers ? null : _refreshUsers,
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('Refresh'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _userSearchController,
                  onChanged: (String value) {
                    setState(() => _searchQuery = value.trim().toLowerCase());
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
                              setState(() => _searchQuery = '');
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
                        setState(() => _showStudents = value);
                      },
                    ),
                    FilterChip(
                      label: const Text('Instructors'),
                      selected: _showInstructors,
                      onSelected: (bool value) {
                        setState(() => _showInstructors = value);
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
                    filteredDocs = _loadedUserDocs
                        .where((
                          QueryDocumentSnapshot<Map<String, dynamic>> doc,
                        ) {
                          final Map<String, dynamic> data = doc.data();
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
                        .where((
                          QueryDocumentSnapshot<Map<String, dynamic>> doc,
                        ) {
                          final String q = _searchQuery;
                          if (q.isEmpty) {
                            return true;
                          }
                          final Map<String, dynamic> data = doc.data();
                          return _buildSearchHaystack(data, doc.id).contains(q);
                        })
                        .toList(growable: false);

                    if (!_showStudents && !_showInstructors) {
                      return const Text(
                        'Select Students and/or Instructors to filter the list.',
                      );
                    }
                    if (filteredDocs.isEmpty) {
                      return const Text('No users found.');
                    }

                    return SizedBox(
                      height: 420,
                      child: Scrollbar(
                        controller: _allUsersScrollController,
                        thumbVisibility: true,
                        child: ListView.separated(
                          controller: _allUsersScrollController,
                          itemCount: filteredDocs.length + 1,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (BuildContext context, int index) {
                            if (index >= filteredDocs.length) {
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
                              if (!_hasMoreUsers) {
                                return const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 12),
                                  child: Center(child: Text('End of list.')),
                                );
                              }
                              return Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 8,
                                ),
                                child: Center(
                                  child: OutlinedButton.icon(
                                    onPressed: _loadMoreUsers,
                                    icon: const Icon(Icons.expand_more),
                                    label: const Text('Load more'),
                                  ),
                                ),
                              );
                            }

                            final QueryDocumentSnapshot<Map<String, dynamic>>
                            doc = filteredDocs[index];
                            final Map<String, dynamic> data = doc.data();
                            final String name = _resolveDisplayName(
                              data,
                              doc.id,
                            );
                            final String role = (data['role'] as String?) ?? '';
                            final bool hasEnrollment =
                                ((data['faceEmbeds'] is List) &&
                                    (data['faceEmbeds'] as List).isNotEmpty) ||
                                ((data['faceEmbed'] is List) &&
                                    (data['faceEmbed'] as List).isNotEmpty);
                            final bool approved = data['approved'] == true;

                            return ListTile(
                              contentPadding: EdgeInsets.zero,
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
                              trailing: PopupMenuButton<String>(
                                onSelected: (String action) {
                                  switch (action) {
                                    case 'edit':
                                      _editUserProfile(doc);
                                      break;
                                    case 'approve':
                                      _approveInstructor(doc.id);
                                      break;
                                    case 'migrateEnrollment':
                                      _migrateFaceEnrollmentFormat(doc.id);
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
                                    if (role.toLowerCase() == 'instructor' &&
                                        !approved)
                                      const PopupMenuItem<String>(
                                        value: 'approve',
                                        child: Text('Approve instructor'),
                                      ),
                                    if (hasEnrollment)
                                      const PopupMenuItem<String>(
                                        value: 'migrateEnrollment',
                                        child: Text(
                                          'Fix face enrollment format',
                                        ),
                                      ),
                                    if (hasEnrollment)
                                      const PopupMenuItem<String>(
                                        value: 'clearEnrollment',
                                        child: Text('Clear face enrollment'),
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
