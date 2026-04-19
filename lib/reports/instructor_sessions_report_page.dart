import 'dart:convert';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../services/user_role_service.dart';
import 'save_bytes.dart';

class InstructorSessionsReportPage extends StatefulWidget {
  const InstructorSessionsReportPage({super.key});

  static const String routeName = '/reports/instructor-sessions';

  @override
  State<InstructorSessionsReportPage> createState() =>
      _InstructorSessionsReportPageState();
}

class _InstructorSessionsReportPageState
    extends State<InstructorSessionsReportPage> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  bool _checkingAccess = true;
  bool _isAdmin = false;

  bool _loading = false;
  DateTimeRange _range = DateTimeRange(
    start: DateTime.now().subtract(const Duration(days: 6)),
    end: DateTime.now(),
  );

  List<_InstructorSummary> _summaries = <_InstructorSummary>[];
  int _sessionsTotal = 0;
  int _completedSessionsTotal = 0;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final String? uid = _auth.currentUser?.uid;
    final String? role = await UserRoleService.fetchRoleByUid(uid);
    if (!mounted) return;

    setState(() {
      _isAdmin = (role ?? '').toLowerCase() == 'admin';
      _checkingAccess = false;
    });

    if (_isAdmin) {
      await _refresh();
    }
  }

  DateTime _dayKey(DateTime dt) => DateTime(dt.year, dt.month, dt.day);

  (DateTime start, DateTime endExclusive) _rangeWindow() {
    final DateTime start = _dayKey(_range.start);
    final DateTime endExclusive = _dayKey(
      _range.end,
    ).add(const Duration(days: 1));
    return (start, endExclusive);
  }

  Future<void> _pickRange() async {
    final DateTime now = DateTime.now();
    final DateTime first = DateTime(now.year - 2, 1, 1);
    final DateTime last = DateTime(now.year + 1, 12, 31);

    final DateTimeRange? picked = await showDateRangePicker(
      context: context,
      firstDate: first,
      lastDate: last,
      initialDateRange: _range,
    );
    if (picked == null || !mounted) return;
    setState(() => _range = picked);
    await _refresh();
  }

  Future<Map<String, _InstructorIdentity>> _fetchInstructorIdentities(
    Set<String> instructorIds,
  ) async {
    if (instructorIds.isEmpty) return <String, _InstructorIdentity>{};

    const int chunkSize = 10;
    final Map<String, _InstructorIdentity> out =
        <String, _InstructorIdentity>{};

    final List<String> ids = instructorIds.toList(growable: false);
    for (int i = 0; i < ids.length; i += chunkSize) {
      final List<String> chunk = ids.sublist(
        i,
        (i + chunkSize).clamp(0, ids.length),
      );
      try {
        final QuerySnapshot<Map<String, dynamic>> snap = await _firestore
            .collection('users')
            .where(FieldPath.documentId, whereIn: chunk)
            .get(const GetOptions(source: Source.server));

        for (final QueryDocumentSnapshot<Map<String, dynamic>> d in snap.docs) {
          out[d.id] = _InstructorIdentity.fromUserDoc(d);
        }
      } catch (_) {
        // Best-effort only.
      }
    }

    return out;
  }

  Future<void> _refresh() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _summaries = <_InstructorSummary>[];
      _sessionsTotal = 0;
      _completedSessionsTotal = 0;
    });

    try {
      final (DateTime start, DateTime endExclusive) = _rangeWindow();

      final Map<String, QueryDocumentSnapshot<Map<String, dynamic>>> byId =
          <String, QueryDocumentSnapshot<Map<String, dynamic>>>{};

      Future<void> fetchInto(Query<Map<String, dynamic>> q) async {
        QuerySnapshot<Map<String, dynamic>> snap;
        try {
          snap = await q.get(const GetOptions(source: Source.server));
        } catch (_) {
          snap = await q.get(const GetOptions(source: Source.cache));
        }
        for (final QueryDocumentSnapshot<Map<String, dynamic>> doc
            in snap.docs) {
          byId.putIfAbsent(doc.id, () => doc);
        }
      }

      await fetchInto(
        _firestore
            .collection('attendanceSessions')
            .orderBy('effectiveStartedAt', descending: true)
            .where(
              'effectiveStartedAt',
              isGreaterThanOrEqualTo: Timestamp.fromDate(start),
            )
            .where(
              'effectiveStartedAt',
              isLessThan: Timestamp.fromDate(endExclusive),
            ),
      );

      await fetchInto(
        _firestore
            .collection('attendanceSessions')
            .orderBy('startedAt', descending: true)
            .where(
              'startedAt',
              isGreaterThanOrEqualTo: Timestamp.fromDate(start),
            )
            .where('startedAt', isLessThan: Timestamp.fromDate(endExclusive)),
      );

      final List<QueryDocumentSnapshot<Map<String, dynamic>>> docs = byId.values
          .toList(growable: false);
      docs.sort((a, b) {
        DateTime? ts(Map<String, dynamic> data, String key) {
          final Object? v = data[key];
          return v is Timestamp ? v.toDate() : null;
        }

        final Map<String, dynamic> ad = a.data();
        final Map<String, dynamic> bd = b.data();
        final DateTime aStarted =
            ts(ad, 'effectiveStartedAt') ??
            ts(ad, 'startedAt') ??
            DateTime(1970);
        final DateTime bStarted =
            ts(bd, 'effectiveStartedAt') ??
            ts(bd, 'startedAt') ??
            DateTime(1970);
        return bStarted.compareTo(aStarted);
      });

      final List<_SessionRow> completed = <_SessionRow>[];
      final List<_SessionRow> all = <_SessionRow>[];
      for (final QueryDocumentSnapshot<Map<String, dynamic>> doc in docs) {
        final _SessionRow? row = _SessionRow.fromDoc(doc);
        if (row == null) continue;
        all.add(row);
        if (row.isCompleted) {
          completed.add(row);
        }
      }

      final Set<String> instructorIds = all
          .map((e) => e.instructorId)
          .where((e) => e.trim().isNotEmpty)
          .toSet();

      final Map<String, _InstructorIdentity> identities =
          await _fetchInstructorIdentities(instructorIds);

      final Map<String, List<_SessionRow>> byInstructor =
          <String, List<_SessionRow>>{};
      for (final _SessionRow row in all) {
        final String key = row.instructorId.trim().isEmpty
            ? '(unknown)'
            : row.instructorId.trim();
        (byInstructor[key] ??= <_SessionRow>[]).add(row);
      }

      final List<_InstructorSummary> summaries = <_InstructorSummary>[];
      byInstructor.forEach((String id, List<_SessionRow> rows) {
        rows.sort((a, b) {
          final DateTime aKey =
            a.startedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
          final DateTime bKey =
            b.startedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
          return bKey.compareTo(aKey);
        });

        final _InstructorIdentity? ident = identities[id];
        final String emailFallback = rows
            .map((e) => e.instructorEmail.trim())
            .where((e) => e.isNotEmpty)
            .cast<String>()
            .fold<String>('', (prev, e) => prev.isEmpty ? e : prev);

        final String name =
            ident?.displayName ??
            (id == '(unknown)' ? 'Unknown instructor' : id);
        final String email = (ident?.email ?? '').trim().isNotEmpty
            ? ident!.email
            : emailFallback;

        summaries.add(
          _InstructorSummary(
            instructorId: id,
            instructorName: name,
            instructorEmail: email,
            sessions: rows,
          ),
        );
      });

      summaries.sort((a, b) {
        final int byCount = b.completedCount.compareTo(a.completedCount);
        if (byCount != 0) return byCount;
        final int byTotal = b.totalCount.compareTo(a.totalCount);
        if (byTotal != 0) return byTotal;
        return a.instructorName.toLowerCase().compareTo(
          b.instructorName.toLowerCase(),
        );
      });

      if (!mounted) return;
      setState(() {
        _summaries = summaries;
        _sessionsTotal = all.length;
        _completedSessionsTotal = completed.length;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to build report: $error')));
    }
  }

  String _fmtDateTime(DateTime? dt) {
    if (dt == null) return '—';
    final DateTime local = dt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
  }

  String _fmtRange(DateTimeRange r) {
    String two(int n) => n.toString().padLeft(2, '0');
    String d(DateTime x) => '${x.year}-${two(x.month)}-${two(x.day)}';
    return '${d(r.start)} → ${d(r.end)}';
  }

  Future<void> _exportCsv() async {
    if (_loading) return;
    final List<_InstructorSummary> summaries = _summaries;
    if (summaries.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('No data to export.')));
      return;
    }

    final List<List<String>> rows = <List<String>>[];
    rows.add(<String>[
      'Instructor Name',
      'Instructor Email',
      'Instructor ID',
      'Session ID',
      'Class ID',
      'Subject Code',
      'Subject Name',
      'Section',
      'Term',
      'Location',
      'Status',
      'Started At',
      'Ended At',
      'Duration (minutes)',
    ]);

    for (final _InstructorSummary s in summaries) {
      for (final _SessionRow sess in s.sessions) {
        rows.add(<String>[
          s.instructorName,
          s.instructorEmail,
          s.instructorId,
          sess.sessionId,
          sess.classId,
          sess.subjectCode,
          sess.subjectName,
          sess.section,
          sess.term,
          sess.location,
          sess.status,
          _fmtDateTime(sess.startedAt),
          _fmtDateTime(sess.endedAt),
          sess.durationMinutes?.toString() ?? '',
        ]);
      }
    }

    String esc(String s) {
      final String v = s.replaceAll('"', '""');
      return '"$v"';
    }

    final String csv = rows.map((r) => r.map(esc).join(',')).join('\n');
    final Uint8List bytes = Uint8List.fromList(utf8.encode(csv));

    final String safeRange = _fmtRange(
      _range,
    ).replaceAll(' ', '').replaceAll('→', '-');
    final String fileName = 'instructor_sessions_$safeRange.csv';

    await saveBytesAsFile(bytes, fileName);

    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Exported $fileName')));
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    if (_checkingAccess) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (!_isAdmin) {
      return Scaffold(
        appBar: AppBar(title: const Text('Instructor Sessions Report')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Text('This report is only available to admin accounts.'),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Instructor Sessions Report'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Pick date range',
            onPressed: _loading ? null : _pickRange,
            icon: const Icon(Icons.date_range),
          ),
          IconButton(
            tooltip: 'Export CSV',
            onPressed: _loading ? null : _exportCsv,
            icon: const Icon(Icons.download),
          ),
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loading ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                Chip(
                  avatar: const Icon(Icons.date_range, size: 18),
                  label: Text(_fmtRange(_range)),
                ),
                Chip(
                  avatar: const Icon(Icons.fact_check_outlined, size: 18),
                  label: Text(
                    'Sessions: $_sessionsTotal • Completed: $_completedSessionsTotal',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_loading)
              const LinearProgressIndicator()
            else if (_summaries.isEmpty)
              Text(
                'No sessions found in this range.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            else
              Expanded(
                child: ListView.separated(
                  itemCount: _summaries.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (BuildContext context, int index) {
                    final _InstructorSummary s = _summaries[index];
                    return Card(
                      child: ExpansionTile(
                        leading: const Icon(Icons.person_outline),
                        title: Text(s.instructorName),
                        subtitle: Text(
                          [
                            if (s.instructorEmail.trim().isNotEmpty)
                              s.instructorEmail.trim(),
                            '${s.totalCount} session(s) • ${s.completedCount} completed',
                            'Last ended: ${_fmtDateTime(s.lastEndedAt)}',
                          ].join(' • '),
                        ),
                        children: <Widget>[
                          const Divider(height: 1),
                          ...s.sessions.map((sess) {
                            final String top = [
                              sess.subjectCode.trim().isEmpty
                                  ? sess.subjectName
                                  : sess.subjectCode,
                              if (sess.section.trim().isNotEmpty)
                                'Section ${sess.section}',
                              if (sess.term.trim().isNotEmpty) sess.term,
                            ].where((e) => e.trim().isNotEmpty).join(' • ');

                            final String bottom = [
                              'Started: ${_fmtDateTime(sess.startedAt)}',
                              'Ended: ${_fmtDateTime(sess.endedAt)}',
                              if (sess.durationMinutes != null)
                                'Duration: ${sess.durationMinutes}m',
                            ].join(' • ');

                            return ListTile(
                              dense: true,
                              title: Text(
                                top.isEmpty ? 'Session ${sess.sessionId}' : top,
                              ),
                              subtitle: Text(bottom),
                              trailing: Text(
                                sess.status,
                                style: TextStyle(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            );
                          }),
                        ],
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _InstructorIdentity {
  const _InstructorIdentity({required this.displayName, required this.email});

  final String displayName;
  final String email;

  static _InstructorIdentity fromUserDoc(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final Map<String, dynamic> data = doc.data();
    final List<String?> candidates = <String?>[
      data['displayName'] as String?,
      data['Full Name'] as String?,
      data['fullName'] as String?,
      data['name'] as String?,
      data['Email'] as String?,
      data['email'] as String?,
    ];

    String bestName = '';
    for (final String? candidate in candidates) {
      final String v = (candidate ?? '').trim();
      if (v.isNotEmpty) {
        bestName = v;
        break;
      }
    }

    final String email =
        ((data['Email'] as String?) ?? (data['email'] as String?) ?? '').trim();

    return _InstructorIdentity(
      displayName: bestName.isEmpty ? doc.id : bestName,
      email: email,
    );
  }
}

class _InstructorSummary {
  const _InstructorSummary({
    required this.instructorId,
    required this.instructorName,
    required this.instructorEmail,
    required this.sessions,
  });

  final String instructorId;
  final String instructorName;
  final String instructorEmail;
  final List<_SessionRow> sessions;

  int get totalCount => sessions.length;

  int get completedCount => sessions.where((e) => e.isCompleted).length;

  DateTime? get lastEndedAt {
    if (sessions.isEmpty) return null;
    return sessions.map((e) => e.endedAt).whereType<DateTime>().fold<DateTime?>(
      null,
      (prev, dt) {
        if (prev == null) return dt;
        return dt.isAfter(prev) ? dt : prev;
      },
    );
  }
}

class _SessionRow {
  const _SessionRow({
    required this.sessionId,
    required this.classId,
    required this.subjectCode,
    required this.subjectName,
    required this.section,
    required this.term,
    required this.location,
    required this.instructorId,
    required this.instructorEmail,
    required this.status,
    required this.startedAt,
    required this.endedAt,
  });

  final String sessionId;
  final String classId;
  final String subjectCode;
  final String subjectName;
  final String section;
  final String term;
  final String location;
  final String instructorId;
  final String instructorEmail;
  final String status;
  final DateTime? startedAt;
  final DateTime? endedAt;

  bool get isCompleted {
    return status.toLowerCase() == 'completed' && endedAt != null;
  }

  int? get durationMinutes {
    final DateTime? s = startedAt;
    final DateTime? e = endedAt;
    if (s == null || e == null) return null;
    final int mins = e.difference(s).inMinutes;
    return mins < 0 ? null : mins;
  }

  static _SessionRow? fromDoc(QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final Map<String, dynamic> data = doc.data();
    final String status = (data['status']?.toString() ?? '').trim();

    DateTime? ts(Object? v) {
      if (v is Timestamp) return v.toDate();
      return null;
    }

    return _SessionRow(
      sessionId: doc.id,
      classId: (data['classId']?.toString() ?? '').trim(),
      subjectCode: (data['subjectCode']?.toString() ?? '').trim(),
      subjectName: (data['subjectName']?.toString() ?? '').trim(),
      section: (data['section']?.toString() ?? '').trim(),
      term: (data['term']?.toString() ?? '').trim(),
      location: (data['location']?.toString() ?? '').trim(),
      instructorId: (data['instructorId']?.toString() ?? '').trim(),
      instructorEmail: (data['instructorEmail']?.toString() ?? '').trim(),
      status: status,
      startedAt: ts(data['effectiveStartedAt']) ?? ts(data['startedAt']),
      endedAt: ts(data['effectiveEndedAt']) ?? ts(data['endedAt']),
    );
  }
}
