import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'analytics_dashboard_page.dart';
import 'analytics_student_picker_page.dart';

enum AnalyticsViewerRole { admin, instructor, student }

class AnalyticsClassPickerPage extends StatefulWidget {
  const AnalyticsClassPickerPage({
    super.key,
    required this.viewerRole,
    this.studentId,
    this.studentSection,
  });

  final AnalyticsViewerRole viewerRole;
  final String? studentId;
  final String? studentSection;

  @override
  State<AnalyticsClassPickerPage> createState() =>
      _AnalyticsClassPickerPageState();
}

class _AnalyticsClassPickerPageState extends State<AnalyticsClassPickerPage> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  Query<Map<String, dynamic>> _buildQuery() {
    final CollectionReference<Map<String, dynamic>> classes = _firestore
        .collection('classes');

    switch (widget.viewerRole) {
      case AnalyticsViewerRole.instructor:
        final String? uid = FirebaseAuth.instance.currentUser?.uid;
        if (uid == null || uid.isEmpty) {
          return classes.limit(0);
        }
        return classes.where('instructorId', isEqualTo: uid);
      case AnalyticsViewerRole.student:
        final String section = (widget.studentSection ?? '').trim();
        if (section.isEmpty) {
          return classes.limit(0);
        }
        return classes.where('section', isEqualTo: section);
      case AnalyticsViewerRole.admin:
        return classes;
    }
  }

  String _titleForRole() {
    return switch (widget.viewerRole) {
      AnalyticsViewerRole.admin => 'Select a class',
      AnalyticsViewerRole.instructor => 'Select a class',
      AnalyticsViewerRole.student => 'Select a class',
    };
  }

  Future<void> _openClass(AnalyticsClassInfo info) async {
    final NavigatorState nav = Navigator.of(context);

    if (widget.viewerRole == AnalyticsViewerRole.student) {
      final String? studentId = widget.studentId;
      if (studentId == null || studentId.trim().isEmpty) {
        return;
      }
      await nav.push(
        MaterialPageRoute<void>(
          builder: (BuildContext context) => AnalyticsDashboardPage(
            classInfo: info,
            studentId: studentId,
            studentName: null,
          ),
        ),
      );
      return;
    }

    await nav.push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) =>
            AnalyticsStudentPickerPage(classInfo: info),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Query<Map<String, dynamic>> query = _buildQuery();

    return Scaffold(
      appBar: AppBar(title: Text(_titleForRole())),
      body: SafeArea(
        child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: query.snapshots(),
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
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text('Failed to load classes: ${snapshot.error}'),
                    ),
                  );
                }

                final List<AnalyticsClassInfo> classes =
                    (snapshot.data?.docs ??
                            const <
                              QueryDocumentSnapshot<Map<String, dynamic>>
                            >[])
                        .map(AnalyticsClassInfo.fromDoc)
                        .whereType<AnalyticsClassInfo>()
                        .toList()
                      ..sort((a, b) {
                        final int sectionCmp = a.section.compareTo(b.section);
                        if (sectionCmp != 0) return sectionCmp;
                        final int codeCmp = a.subjectCode.compareTo(
                          b.subjectCode,
                        );
                        if (codeCmp != 0) return codeCmp;
                        return a.subjectName.compareTo(b.subjectName);
                      });

                if (classes.isEmpty) {
                  final String message = switch (widget.viewerRole) {
                    AnalyticsViewerRole.student =>
                      'No classes found for your section.',
                    AnalyticsViewerRole.instructor =>
                      'No assigned classes found.',
                    AnalyticsViewerRole.admin => 'No classes found.',
                  };
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        message,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyLarge,
                      ),
                    ),
                  );
                }

                return ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: classes.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (BuildContext context, int index) {
                    final AnalyticsClassInfo info = classes[index];
                    final String title = info.subjectName.isNotEmpty
                        ? '${info.subjectCode} • ${info.subjectName}'
                        : (info.subjectCode.isNotEmpty
                              ? info.subjectCode
                              : 'Class');
                    final String subtitleParts = <String>[
                      if (info.section.isNotEmpty) 'Section ${info.section}',
                      if (info.term.isNotEmpty) info.term,
                    ].join(' • ');

                    return Card(
                      child: ListTile(
                        leading: const Icon(Icons.class_outlined),
                        title: Text(title),
                        subtitle: subtitleParts.isEmpty
                            ? null
                            : Text(subtitleParts),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _openClass(info),
                      ),
                    );
                  },
                );
              },
        ),
      ),
    );
  }
}

class AnalyticsClassInfo {
  AnalyticsClassInfo({
    required this.id,
    required this.subjectCode,
    required this.subjectName,
    required this.section,
    required this.term,
  });

  final String id;
  final String subjectCode;
  final String subjectName;
  final String section;
  final String term;

  static AnalyticsClassInfo? fromDoc(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final Map<String, dynamic> data = doc.data();
    return AnalyticsClassInfo(
      id: doc.id,
      subjectCode: (data['subjectCode'] as String?)?.trim() ?? '',
      subjectName: (data['subjectName'] as String?)?.trim() ?? '',
      section: (data['section'] as String?)?.trim() ?? '',
      term: (data['term'] as String?)?.trim() ?? '',
    );
  }
}
