import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

class NotificationsPage extends StatefulWidget {
  const NotificationsPage({super.key});

  static const String routeName = '/notifications';

  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage> {
  bool _markingAllRead = false;

  Future<void> _markAllAsRead({required String uid}) async {
    if (_markingAllRead) return;
    setState(() => _markingAllRead = true);
    try {
      final CollectionReference<Map<String, dynamic>> notifications =
          FirebaseFirestore.instance
              .collection('users')
              .doc(uid)
              .collection('notifications');

      // Only unread notifications.
      final QuerySnapshot<Map<String, dynamic>> snap =
          await notifications.where('readAt', isNull: true).get();
      if (snap.docs.isEmpty) return;

      // Batch limit is 500 writes.
      const int chunkSize = 450;
      for (int i = 0; i < snap.docs.length; i += chunkSize) {
        final WriteBatch batch = FirebaseFirestore.instance.batch();
        final Iterable<QueryDocumentSnapshot<Map<String, dynamic>>> chunk = snap
            .docs
            .skip(i)
            .take(chunkSize);
        for (final QueryDocumentSnapshot<Map<String, dynamic>> doc in chunk) {
          batch.update(doc.reference, <String, Object?>{
            'readAt': FieldValue.serverTimestamp(),
          });
        }
        await batch.commit();
      }
    } catch (_) {
      // Best-effort.
    } finally {
      if (mounted) setState(() => _markingAllRead = false);
    }
  }

  static String _formatTimeFromStartMin(int startMin) {
    final int hh = (startMin ~/ 60) % 24;
    final int mm = startMin % 60;
    return '${hh.toString().padLeft(2, '0')}:${mm.toString().padLeft(2, '0')}';
  }

  static String _humanizeMinutes(int minutes) {
    if (minutes <= 0) return '0m';
    final int h = minutes ~/ 60;
    final int m = minutes % 60;
    if (h == 0) return '${m}m';
    if (m == 0) return '${h}h';
    return '${h}h ${m}m';
  }

  static Map<String, dynamic> _payloadFrom(Map<String, dynamic> data) {
    return data['data'] is Map
        ? Map<String, dynamic>.from(data['data'] as Map)
        : <String, dynamic>{};
  }

  static int? _intFromPayload(Map<String, dynamic> payload, String key) {
    final Object? v = payload[key];
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '');
  }

  static String _stringFromPayload(Map<String, dynamic> payload, String key) {
    return (payload[key] ?? '').toString().trim();
  }

  Future<_ScheduleNotificationDetails?> _loadScheduleDetails({
    required Map<String, dynamic> data,
  }) async {
    final Map<String, dynamic> payload = _payloadFrom(data);
    final String classId = (payload['classId'] ?? '').toString().trim();
    if (classId.isEmpty) return null;

    try {
      final DocumentSnapshot<Map<String, dynamic>> classSnap =
          await FirebaseFirestore.instance.collection('classes').doc(classId).get();
      if (!classSnap.exists) return null;
      final Map<String, dynamic> classData = classSnap.data() ?? <String, dynamic>{};

      final String subjectCode = (classData['subjectCode'] ?? '').toString().trim();
      final String subjectName = (classData['subjectName'] ?? '').toString().trim();
      final String section = (payload['section'] ?? classData['section'] ?? '').toString().trim();

      final String instructorId = (classData['instructorId'] ?? '').toString().trim();
      String instructorName = '';
      if (instructorId.isNotEmpty) {
        final DocumentSnapshot<Map<String, dynamic>> instructorSnap =
            await FirebaseFirestore.instance.collection('users').doc(instructorId).get();
        if (instructorSnap.exists) {
          final Map<String, dynamic> u = instructorSnap.data() ?? <String, dynamic>{};
          instructorName =
              (u['displayName'] ?? u['Full Name'] ?? u['name'] ?? '').toString().trim();
          if (instructorName.isEmpty) {
            instructorName = (u['email'] ?? u['Email'] ?? '').toString().trim();
          }
        }
      }

      final String dateKey = (payload['dateKey'] ?? '').toString().trim();
        final int? startMin = _intFromPayload(payload, 'startMin');

      return _ScheduleNotificationDetails(
        classId: classId,
        subject: subjectName.isNotEmpty
            ? '${subjectCode.isNotEmpty ? '$subjectCode • ' : ''}$subjectName'
            : (subjectCode.isNotEmpty ? subjectCode : 'Class'),
        instructor: instructorName,
        section: section,
        dateKey: dateKey,
        startTime: startMin == null ? '' : _formatTimeFromStartMin(startMin),
      );
    } catch (_) {
      return null;
    }
  }

  Future<_NotificationDialogDetails> _loadNotificationDetails({
    required String type,
    required String notificationId,
    required Map<String, dynamic> data,
  }) async {
    final Map<String, dynamic> payload = _payloadFrom(data);

    // Schedule reminders are handled separately via _loadScheduleDetails.
    if (type == 'next_class') {
      return const _NotificationDialogDetails(rows: <_KeyValueRow>[]);
    }

    try {
      if (type == 'excuse_submitted' || type == 'excuse_approved') {
        final String requestId = _stringFromPayload(payload, 'requestId');
        if (requestId.isEmpty) {
          return _NotificationDialogDetails(
            rows: _payloadRows(payload),
          );
        }
        final DocumentSnapshot<Map<String, dynamic>> reqSnap =
            await FirebaseFirestore.instance
                .collection('excuseRequests')
                .doc(requestId)
                .get();
        if (!reqSnap.exists) {
          return _NotificationDialogDetails(
            rows: <_KeyValueRow>[...
              <_KeyValueRow>[
                const _KeyValueRow('Request ID', '(missing)'),
              ],
              ..._payloadRows(payload),
            ],
          );
        }
        final Map<String, dynamic> req = reqSnap.data() ?? <String, dynamic>{};
        final String studentName =
            (req['studentName'] ?? '').toString().trim();
        final String studentSection =
            (req['studentSection'] ?? '').toString().trim();
        final String reason = (req['reason'] ?? '').toString().trim();
        final String status = (req['status'] ?? '').toString().trim();
        final List entries = req['entries'] is List ? (req['entries'] as List) : const <Object>[];

        String entriesText() {
          if (entries.isEmpty) return '';
          final List<String> lines = <String>[];
          for (final Object e in entries) {
            if (e is! Map) continue;
            final String dateKey = (e['dateKey'] ?? '').toString().trim();
            final bool isFullDay = e['isFullDay'] == true;
            if (dateKey.isEmpty) continue;
            if (isFullDay) {
              lines.add('- $dateKey (full day)');
              continue;
            }
            final Object? s = e['startTime'];
            final Object? en = e['endTime'];
            int? sMin;
            int? eMin;
            if (s is Map && s['minutes'] is num) sMin = (s['minutes'] as num).toInt();
            if (en is Map && en['minutes'] is num) eMin = (en['minutes'] as num).toInt();
            final String start = sMin == null ? '' : _formatTimeFromStartMin(sMin);
            final String end = eMin == null ? '' : _formatTimeFromStartMin(eMin);
            final String window = (start.isNotEmpty && end.isNotEmpty) ? '$start–$end' : '';
            lines.add(window.isEmpty ? '- $dateKey' : '- $dateKey ($window)');
          }
          return lines.join('\n');
        }

        return _NotificationDialogDetails(
          rows: <_KeyValueRow>[
            _KeyValueRow('Notification ID', notificationId),
            _KeyValueRow('Type', type),
            _KeyValueRow('Request ID', requestId),
            if (studentName.isNotEmpty) _KeyValueRow('Student', studentName),
            if (studentSection.isNotEmpty)
              _KeyValueRow('Section', studentSection),
            if (status.isNotEmpty) _KeyValueRow('Status', status),
            if (reason.isNotEmpty) _KeyValueRow('Reason', reason),
            if (entriesText().isNotEmpty)
              _KeyValueRow('Requested Dates', entriesText()),
          ],
        );
      }

      if (type == 'absence_threshold' || type == 'student_absence_threshold') {
        final String classId = _stringFromPayload(payload, 'classId');
        final int? absentMinutes = _intFromPayload(payload, 'absentMinutes');
        final int? thresholdMinutes = _intFromPayload(payload, 'thresholdMinutes');
        final String studentId = _stringFromPayload(payload, 'studentId');

        String subjectLabel = '';
        String instructorName = '';
        String section = '';
        if (classId.isNotEmpty) {
          final DocumentSnapshot<Map<String, dynamic>> classSnap =
              await FirebaseFirestore.instance
                  .collection('classes')
                  .doc(classId)
                  .get();
          if (classSnap.exists) {
            final Map<String, dynamic> c = classSnap.data() ?? <String, dynamic>{};
            final String subjectCode = (c['subjectCode'] ?? '').toString().trim();
            final String subjectName = (c['subjectName'] ?? '').toString().trim();
            section = (c['section'] ?? '').toString().trim();
            subjectLabel = subjectName.isNotEmpty
                ? '${subjectCode.isNotEmpty ? '$subjectCode • ' : ''}$subjectName'
                : subjectCode;

            final String instructorId = (c['instructorId'] ?? '').toString().trim();
            if (instructorId.isNotEmpty) {
              final DocumentSnapshot<Map<String, dynamic>> instructorSnap =
                  await FirebaseFirestore.instance
                      .collection('users')
                      .doc(instructorId)
                      .get();
              if (instructorSnap.exists) {
                final Map<String, dynamic> u = instructorSnap.data() ?? <String, dynamic>{};
                instructorName = (u['displayName'] ?? u['Full Name'] ?? u['name'] ?? '').toString().trim();
                if (instructorName.isEmpty) {
                  instructorName = (u['email'] ?? u['Email'] ?? '').toString().trim();
                }
              }
            }
          }
        }

        String studentName = '';
        if (type == 'student_absence_threshold' && studentId.isNotEmpty) {
          final DocumentSnapshot<Map<String, dynamic>> studentSnap =
              await FirebaseFirestore.instance.collection('users').doc(studentId).get();
          if (studentSnap.exists) {
            final Map<String, dynamic> u = studentSnap.data() ?? <String, dynamic>{};
            studentName = (u['displayName'] ?? u['Full Name'] ?? '').toString().trim();
            if (studentName.isEmpty) {
              studentName = (u['email'] ?? u['Email'] ?? '').toString().trim();
            }
          }
        }

        return _NotificationDialogDetails(
          rows: <_KeyValueRow>[
            _KeyValueRow('Notification ID', notificationId),
            _KeyValueRow('Type', type),
            if (subjectLabel.isNotEmpty) _KeyValueRow('Subject', subjectLabel),
            if (instructorName.isNotEmpty)
              _KeyValueRow('Instructor', instructorName),
            if (section.isNotEmpty) _KeyValueRow('Section', section),
            if (type == 'student_absence_threshold' && studentName.isNotEmpty)
              _KeyValueRow('Student', studentName),
            if (absentMinutes != null)
              _KeyValueRow('Total Absences', _humanizeMinutes(absentMinutes)),
            if (thresholdMinutes != null)
              _KeyValueRow('Threshold', _humanizeMinutes(thresholdMinutes)),
            if (classId.isNotEmpty) _KeyValueRow('Class ID', classId),
            if (type == 'student_absence_threshold' && studentId.isNotEmpty)
              _KeyValueRow('Student ID', studentId),
          ],
        );
      }

      // Unknown type: show payload.
      return _NotificationDialogDetails(
        rows: <_KeyValueRow>[
          _KeyValueRow('Notification ID', notificationId),
          _KeyValueRow('Type', type),
          ..._payloadRows(payload),
        ],
      );
    } catch (_) {
      return _NotificationDialogDetails(
        rows: <_KeyValueRow>[
          _KeyValueRow('Notification ID', notificationId),
          _KeyValueRow('Type', type),
          ..._payloadRows(payload),
        ],
      );
    }
  }

  static List<_KeyValueRow> _payloadRows(Map<String, dynamic> payload) {
    if (payload.isEmpty) return const <_KeyValueRow>[];
    final List<String> keys = payload.keys.map((k) => k.toString()).toList()..sort();
    return keys
        .map((k) => _KeyValueRow(k, (payload[k] ?? '').toString()))
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final User? user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return const Scaffold(
        body: SafeArea(
          child: Center(child: Text('You must be signed in.')),
        ),
      );
    }

    final CollectionReference<Map<String, dynamic>> notifications =
        FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .collection('notifications');

    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications'),
        actions: <Widget>[
          TextButton(
            onPressed: _markingAllRead ? null : () => _markAllAsRead(uid: user.uid),
            child: _markingAllRead
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Mark all as read'),
          ),
        ],
      ),
      body: SafeArea(
        child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: notifications.orderBy('createdAt', descending: true).snapshots(),
          builder: (
            BuildContext context,
            AsyncSnapshot<QuerySnapshot<Map<String, dynamic>>> snapshot,
          ) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('Failed to load notifications.'),
                ),
              );
            }

            final List<QueryDocumentSnapshot<Map<String, dynamic>>> docs =
                snapshot.data?.docs ??
                <QueryDocumentSnapshot<Map<String, dynamic>>>[];
            if (docs.isEmpty) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('No notifications yet.'),
                ),
              );
            }

            return ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: docs.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (BuildContext context, int index) {
                final QueryDocumentSnapshot<Map<String, dynamic>> doc = docs[index];
                final Map<String, dynamic> data = doc.data();
                final String title = (data['title'] as String?) ?? 'Notification';
                final String body = (data['body'] as String?) ?? '';
                final Timestamp? createdAt = data['createdAt'] as Timestamp?;
                final Timestamp? readAt = data['readAt'] as Timestamp?;
                final String type = (data['type'] as String?) ?? 'generic';

                final bool isUnread = readAt == null;
                final DateTime? created = createdAt?.toDate();

                return ListTile(
                  title: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: isUnread
                        ? const TextStyle(fontWeight: FontWeight.w700)
                        : null,
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      if (body.isNotEmpty)
                        Text(
                          body,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      if (created != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            _formatWhen(created),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                    ],
                  ),
                  trailing: isUnread
                      ? Icon(
                          Icons.circle,
                          size: 10,
                          color: Theme.of(context).colorScheme.primary,
                        )
                      : null,
                  onTap: () async {
                    // Show full details.
                    await showDialog<void>(
                      context: context,
                      builder: (BuildContext context) {
                        final bool isSchedule = type == 'next_class';
                        return AlertDialog(
                          title: Text(title),
                          content: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 520),
                            child: SingleChildScrollView(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  if (body.isNotEmpty) Text(body),
                                  if (created != null) ...<Widget>[
                                    const SizedBox(height: 12),
                                    Text(
                                      _formatWhenFull(created),
                                      style: Theme.of(context).textTheme.bodySmall,
                                    ),
                                  ],
                                  if (readAt != null) ...<Widget>[
                                    const SizedBox(height: 4),
                                    Text(
                                      'Read: ${_formatWhenFull(readAt.toDate())}',
                                      style: Theme.of(context).textTheme.bodySmall,
                                    ),
                                  ],
                                  if (isSchedule) ...<Widget>[
                                    const SizedBox(height: 16),
                                    FutureBuilder<_ScheduleNotificationDetails?>(
                                      future: _loadScheduleDetails(data: data),
                                      builder: (
                                        BuildContext context,
                                        AsyncSnapshot<_ScheduleNotificationDetails?> snapshot,
                                      ) {
                                        if (snapshot.connectionState == ConnectionState.waiting) {
                                          return const Padding(
                                            padding: EdgeInsets.only(top: 4),
                                            child: LinearProgressIndicator(),
                                          );
                                        }
                                        final _ScheduleNotificationDetails? d = snapshot.data;
                                        if (d == null) {
                                          return Text(
                                            'Schedule details unavailable.',
                                            style: Theme.of(context).textTheme.bodyMedium,
                                          );
                                        }
                                        return Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: <Widget>[
                                            Text('Subject: ${d.subject}'),
                                            if (d.instructor.trim().isNotEmpty)
                                              Text('Instructor: ${d.instructor}'),
                                            if (d.section.trim().isNotEmpty)
                                              Text('Section: ${d.section}'),
                                            if (d.dateKey.trim().isNotEmpty && d.startTime.trim().isNotEmpty)
                                              Text('Schedule: ${d.dateKey} ${d.startTime} (Asia/Manila)'),
                                            if (d.dateKey.trim().isEmpty && d.startTime.trim().isNotEmpty)
                                              Text('Schedule time: ${d.startTime} (Asia/Manila)'),
                                          ],
                                        );
                                      },
                                    ),
                                  ],

                                  const SizedBox(height: 16),
                                  FutureBuilder<_NotificationDialogDetails>(
                                    future: _loadNotificationDetails(
                                      type: type,
                                      notificationId: doc.id,
                                      data: data,
                                    ),
                                    builder: (
                                      BuildContext context,
                                      AsyncSnapshot<_NotificationDialogDetails> snapshot,
                                    ) {
                                      if (snapshot.connectionState == ConnectionState.waiting) {
                                        return const Padding(
                                          padding: EdgeInsets.only(top: 4),
                                          child: LinearProgressIndicator(),
                                        );
                                      }
                                      final _NotificationDialogDetails? details = snapshot.data;
                                      final List<_KeyValueRow> rows = details?.rows ?? const <_KeyValueRow>[];
                                      if (rows.isEmpty) {
                                        return const SizedBox.shrink();
                                      }
                                      return Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: rows
                                            .map(
                                              (_KeyValueRow r) => Padding(
                                                padding: const EdgeInsets.only(top: 6),
                                                child: Text('${r.key}: ${r.value}'),
                                              ),
                                            )
                                            .toList(growable: false),
                                      );
                                    },
                                  ),
                                ],
                              ),
                            ),
                          ),
                          actions: <Widget>[
                            TextButton(
                              onPressed: () => Navigator.of(context).pop(),
                              child: const Text('Close'),
                            ),
                          ],
                        );
                      },
                    );

                    if (isUnread) {
                      try {
                        await doc.reference.update(<String, Object?>{
                          'readAt': FieldValue.serverTimestamp(),
                        });
                      } catch (_) {
                        // Best-effort.
                      }
                    }
                  },
                );
              },
            );
          },
        ),
      ),
    );
  }

  static String _formatWhen(DateTime time) {
    final DateTime now = DateTime.now();
    final Duration diff = now.difference(time);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${time.year.toString().padLeft(4, '0')}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')}';
  }

  static String _formatWhenFull(DateTime time) {
    final DateTime local = time.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.year.toString().padLeft(4, '0')}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
  }
}

class _ScheduleNotificationDetails {
  const _ScheduleNotificationDetails({
    required this.classId,
    required this.subject,
    required this.instructor,
    required this.section,
    required this.dateKey,
    required this.startTime,
  });

  final String classId;
  final String subject;
  final String instructor;
  final String section;
  final String dateKey;
  final String startTime;
}

class _NotificationDialogDetails {
  const _NotificationDialogDetails({required this.rows});

  final List<_KeyValueRow> rows;
}

class _KeyValueRow {
  const _KeyValueRow(this.key, this.value);

  final String key;
  final String value;
}
