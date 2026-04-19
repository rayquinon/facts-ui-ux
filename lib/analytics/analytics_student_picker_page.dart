import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import 'analytics_class_picker_page.dart';
import 'analytics_dashboard_page.dart';

class AnalyticsStudentPickerPage extends StatefulWidget {
  const AnalyticsStudentPickerPage({super.key, required this.classInfo});

  final AnalyticsClassInfo classInfo;

  @override
  State<AnalyticsStudentPickerPage> createState() =>
      _AnalyticsStudentPickerPageState();
}

class _AnalyticsStudentPickerPageState
    extends State<AnalyticsStudentPickerPage> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String section = widget.classInfo.section.trim();

    final Query<Map<String, dynamic>> query = _firestore
        .collection('users')
        .where('role', isEqualTo: 'student')
        .where('section', isEqualTo: section);

    return Scaffold(
      appBar: AppBar(title: const Text('Select a student')),
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
                      child: Text('Failed to load students: ${snapshot.error}'),
                    ),
                  );
                }

                final List<_AnalyticsStudentInfo> students =
                    (snapshot.data?.docs ??
                            const <
                              QueryDocumentSnapshot<Map<String, dynamic>>
                            >[])
                        .map(_AnalyticsStudentInfo.fromDoc)
                        .whereType<_AnalyticsStudentInfo>()
                        .toList()
                      ..sort((a, b) => a.displayName.compareTo(b.displayName));

                if (students.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        section.isEmpty
                            ? 'This class has no section assigned.'
                            : 'No students found for Section $section.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyLarge,
                      ),
                    ),
                  );
                }

                return ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: students.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (BuildContext context, int index) {
                    final _AnalyticsStudentInfo student = students[index];
                    return Card(
                      child: ListTile(
                        leading: const Icon(Icons.person_outline),
                        title: Text(student.displayName),
                        subtitle: student.studentIdLabel == null
                            ? null
                            : Text(student.studentIdLabel!),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (BuildContext context) =>
                                  AnalyticsDashboardPage(
                                    classInfo: widget.classInfo,
                                    studentId: student.uid,
                                    studentName: student.displayName,
                                  ),
                            ),
                          );
                        },
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

class _AnalyticsStudentInfo {
  _AnalyticsStudentInfo({
    required this.uid,
    required this.displayName,
    required this.studentIdLabel,
  });

  final String uid;
  final String displayName;
  final String? studentIdLabel;

  static _AnalyticsStudentInfo? fromDoc(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final Map<String, dynamic> data = doc.data();
    final String name =
        ((data['displayName'] as String?) ?? (data['Full Name'] as String?))
            ?.trim() ??
        '';
    final String displayName = name.isEmpty ? 'Student' : name;

    final String? rawStudentId =
        (data['studentId'] as String?)?.trim() ??
        (data['Student ID'] as String?)?.trim();
    final String? label = (rawStudentId == null || rawStudentId.isEmpty)
        ? null
        : 'ID: $rawStudentId';

    return _AnalyticsStudentInfo(
      uid: doc.id,
      displayName: displayName,
      studentIdLabel: label,
    );
  }
}
