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
  final TextEditingController _searchController = TextEditingController();
  static const int _pageSize = 30;
  final List<_AnalyticsStudentInfo> _allStudents = <_AnalyticsStudentInfo>[];
  final List<_AnalyticsStudentInfo> _students = <_AnalyticsStudentInfo>[];
  DocumentSnapshot<Map<String, dynamic>>? _lastDoc;
  bool _isLoading = false;
  bool _hasMore = true;

  // Whether we've loaded the full student list for this class (via section or attendees fallback)
  bool _allLoaded = false;

  @override
  Widget build(BuildContext context) {
    final String section = widget.classInfo.section.trim();

    return Scaffold(
      appBar: AppBar(title: const Text('Select a student')),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search),
                        hintText: 'Search by name or ID',
                      ),
                      onSubmitted: (_) => _startSearch(section),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => _startSearch(section),
                    child: const Text('Search'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _buildList(section),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: <Widget>[
                  TextButton(
                    onPressed: _hasMore && !_isLoading ? () => _loadMore(section) : null,
                    child: const Text('Load more'),
                  ),
                  Text('${_students.length} shown'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final String section = widget.classInfo.section.trim();
      _loadAllStudentsForClass(section);
    });
  }

  Future<void> _loadAllStudentsForClass(String section) async {
    setState(() => _isLoading = true);
    try {
      if (section.isNotEmpty) {
        final Query<Map<String, dynamic>> ref = _firestore
            .collection('users')
            .where('role', isEqualTo: 'student')
            .where('section', isEqualTo: section);

        QuerySnapshot<Map<String, dynamic>> snap;
        try {
          snap = await ref.get(const GetOptions(source: Source.server));
        } catch (_) {
          snap = await ref.get(const GetOptions(source: Source.cache));
        }
        final List<_AnalyticsStudentInfo> all = snap.docs
            .map(_AnalyticsStudentInfo.fromDoc)
            .whereType<_AnalyticsStudentInfo>()
            .toList()
          ..sort((a, b) => a.displayName.compareTo(b.displayName));

        if (all.isNotEmpty) {
          setState(() {
            _allStudents
              ..clear()
              ..addAll(all);
            _students.clear();
            _students.addAll(all);
            _lastDoc = null;
            _hasMore = false;
            _allLoaded = true;
          });
          return;
        }
      }

      // Fallback: try loading by scanning attendanceSessions->attendees
      await _loadStudentsByClassId();
      setState(() => _allLoaded = _allStudents.isNotEmpty);
    } catch (_) {
      // leave as-is on error
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Widget _buildList(String section) {
    if (_isLoading && _students.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_students.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            section.isEmpty
                ? 'This class has no section assigned.'
                : 'No students found for this class.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: _students.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (BuildContext context, int index) {
        final _AnalyticsStudentInfo student = _students[index];
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
  }

  Future<void> _startSearch(String section) async {
    final String q = _searchController.text.trim();
    setState(() => _isLoading = true);
    try {
      if (!_allLoaded) {
        await _loadAllStudentsForClass(section);
      }

      if (q.isEmpty) {
        setState(() {
          _students
            ..clear()
            ..addAll(_allStudents);
          _hasMore = false;
        });
        return;
      }

      final String lower = q.toLowerCase();
      final List<_AnalyticsStudentInfo> filtered = _allStudents
          .where((e) =>
              e.displayName.toLowerCase().contains(lower) ||
              (e.studentIdLabel ?? '').toLowerCase().contains(lower))
          .toList()
        ..sort((a, b) => a.displayName.compareTo(b.displayName));

      setState(() {
        _students
          ..clear()
          ..addAll(filtered);
        _hasMore = false;
      });
    } catch (_) {
      // ignore errors for now, UI will show empty list
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _loadMore(String section) async {
    if (!_hasMore) return;
    setState(() => _isLoading = true);
    try {
      Query<Map<String, dynamic>> ref = _firestore
          .collection('users')
          .where('role', isEqualTo: 'student')
          .where('section', isEqualTo: section)
          .orderBy('displayName')
          .limit(_pageSize);

      if (_lastDoc != null) {
        ref = ref.startAfterDocument(_lastDoc!);
      }

      final QuerySnapshot<Map<String, dynamic>> snap = await ref.get();
      final List<_AnalyticsStudentInfo> page = snap.docs
          .map(_AnalyticsStudentInfo.fromDoc)
          .whereType<_AnalyticsStudentInfo>()
          .toList()
        ..sort((a, b) => a.displayName.compareTo(b.displayName));

      if (page.isNotEmpty) {
        _students.addAll(page);
        _lastDoc = snap.docs.isNotEmpty ? snap.docs.last : _lastDoc;
      }

      _hasMore = snap.docs.length >= _pageSize;
      // If no users were returned for the section, try fallback by scanning
      // attendanceSessions->attendees for this classId to build the student list.
      if (_students.isEmpty) {
        await _loadStudentsByClassId();
      }
    } catch (_) {
      _hasMore = false;
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _loadStudentsByClassId() async {
    final String classId = widget.classInfo.id;
    final Set<String> uids = <String>{};
    try {
      final QuerySnapshot<Map<String, dynamic>> sessions = await _firestore
          .collection('attendanceSessions')
          .where('classId', isEqualTo: classId)
          .get();

      for (final QueryDocumentSnapshot<Map<String, dynamic>> s in sessions.docs) {
        final QuerySnapshot<Map<String, dynamic>> attendees = await s.reference
            .collection('attendees')
            .get();
        for (final QueryDocumentSnapshot<Map<String, dynamic>> a in attendees.docs) {
          uids.add(a.id);
        }
      }

      if (uids.isEmpty) return;

      final List<Future<DocumentSnapshot<Map<String, dynamic>>>> futures = uids
          .map((String uid) => _firestore.collection('users').doc(uid).get())
          .toList();

      final List<DocumentSnapshot<Map<String, dynamic>>> docs =
          (await Future.wait(futures))
              .whereType<DocumentSnapshot<Map<String, dynamic>>>()
              .where((d) => d.exists)
              .toList();

      final List<_AnalyticsStudentInfo> results = docs
          .map(_AnalyticsStudentInfo.fromSnapshot)
          .whereType<_AnalyticsStudentInfo>()
          .toList()
        ..sort((a, b) => a.displayName.compareTo(b.displayName));

      setState(() {
        _allStudents
          ..clear()
          ..addAll(results);
        _students.clear();
        _students.addAll(results);
        _hasMore = false;
      });
    } catch (_) {
      // ignore errors; leave students empty
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
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

  static _AnalyticsStudentInfo? fromSnapshot(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final Map<String, dynamic> data = doc.data() ?? <String, dynamic>{};
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
