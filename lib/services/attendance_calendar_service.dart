import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

enum AttendanceCalendarDayType { holiday, suspension, examWeek, schoolActivity }

class AttendanceCalendarDay {
  const AttendanceCalendarDay({
    required this.dateKey,
    required this.type,
    required this.code,
    required this.label,
    this.reason,
  });

  final String dateKey;
  final AttendanceCalendarDayType type;
  final String code;
  final String label;
  final String? reason;

  static String dateKeyFor(DateTime date) {
    final String y = date.year.toString().padLeft(4, '0');
    final String m = date.month.toString().padLeft(2, '0');
    final String d = date.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  static AttendanceCalendarDay? fromDoc(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    if (!doc.exists) return null;
    final Map<String, dynamic>? data = doc.data();
    if (data == null) return null;

    final String? rawType = data['type'] as String?;
    final AttendanceCalendarDayType? type = switch (rawType) {
      'holiday' => AttendanceCalendarDayType.holiday,
      'suspension' => AttendanceCalendarDayType.suspension,
      'exam_week' => AttendanceCalendarDayType.examWeek,
      'school_activity' => AttendanceCalendarDayType.schoolActivity,
      _ => null,
    };
    if (type == null) return null;

    final String code = (data['code'] as String?) ?? '';
    final String label = (data['label'] as String?) ?? '';
    if (code.trim().isEmpty || label.trim().isEmpty) return null;

    return AttendanceCalendarDay(
      dateKey: doc.id,
      type: type,
      code: code,
      label: label,
      reason: data['reason'] as String?,
    );
  }
}

class AttendanceCalendarService {
  AttendanceCalendarService({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
  }) : _firestore = firestore ?? FirebaseFirestore.instance,
       _auth = auth ?? FirebaseAuth.instance;

  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;

  CollectionReference<Map<String, dynamic>> get _col =>
      _firestore.collection('attendanceCalendarDays');

  Future<AttendanceCalendarDay?> fetchDayBestEffort({
    required DateTime day,
  }) async {
    final String key = AttendanceCalendarDay.dateKeyFor(day);
    try {
      final doc = await _col
          .doc(key)
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 3));
      return AttendanceCalendarDay.fromDoc(doc);
    } catch (_) {
      try {
        final doc = await _col
            .doc(key)
            .get(const GetOptions(source: Source.cache))
            .timeout(const Duration(seconds: 1));
        return AttendanceCalendarDay.fromDoc(doc);
      } catch (_) {
        return null;
      }
    }
  }

  Future<Map<DateTime, AttendanceCalendarDay>> fetchDaysFor({
    required List<DateTime> days,
  }) async {
    final Map<DateTime, AttendanceCalendarDay> out =
        <DateTime, AttendanceCalendarDay>{};
    if (days.isEmpty) return out;

    final Map<String, DateTime> keyToDay = <String, DateTime>{};
    for (final DateTime d in days) {
      final DateTime normalized = DateTime(d.year, d.month, d.day);
      keyToDay[AttendanceCalendarDay.dateKeyFor(normalized)] = normalized;
    }

    final List<String> keys = keyToDay.keys.toList()..sort();
    const int chunkSize = 10; // Firestore whereIn limit.

    for (int i = 0; i < keys.length; i += chunkSize) {
      final List<String> chunk = keys.sublist(
        i,
        (i + chunkSize).clamp(0, keys.length),
      );
      final QuerySnapshot<Map<String, dynamic>> snap = await _col
          .where(FieldPath.documentId, whereIn: chunk)
          .get();
      for (final QueryDocumentSnapshot<Map<String, dynamic>> doc in snap.docs) {
        final AttendanceCalendarDay? parsed = AttendanceCalendarDay.fromDoc(doc);
        if (parsed == null) continue;
        final DateTime? day = keyToDay[doc.id];
        if (day == null) continue;
        out[day] = parsed;
      }
    }

    return out;
  }

  Future<void> upsertDay({
    required DateTime day,
    required AttendanceCalendarDayType type,
    String? reason,
  }) async {
    final DateTime normalized = DateTime(day.year, day.month, day.day);
    final String key = AttendanceCalendarDay.dateKeyFor(normalized);

    final ({String code, String label, String typeValue}) meta = switch (type) {
      AttendanceCalendarDayType.holiday => (
        code: 'H',
        label: 'Holiday',
        typeValue: 'holiday',
      ),
      AttendanceCalendarDayType.suspension => (
        code: 'S',
        label: 'Class Suspension',
        typeValue: 'suspension',
      ),
      AttendanceCalendarDayType.examWeek => (
        code: 'Ex',
        label: 'Exam Week',
        typeValue: 'exam_week',
      ),
      AttendanceCalendarDayType.schoolActivity => (
        code: 'A',
        label: 'School Activity',
        typeValue: 'school_activity',
      ),
    };

    final String? uid = _auth.currentUser?.uid;

    await _col.doc(key).set(<String, dynamic>{
      'type': meta.typeValue,
      'code': meta.code,
      'label': meta.label,
      if ((reason ?? '').trim().isNotEmpty) 'reason': reason!.trim(),
      'dateKey': key,
      'updatedAt': FieldValue.serverTimestamp(),
      if (uid != null) 'updatedBy': uid,
      'createdAt': FieldValue.serverTimestamp(),
      if (uid != null) 'createdBy': uid,
    }, SetOptions(merge: true));
  }

  Future<void> upsertRange({
    required DateTime start,
    required DateTime end,
    required AttendanceCalendarDayType type,
    String? reason,
  }) async {
    DateTime s = DateTime(start.year, start.month, start.day);
    DateTime e = DateTime(end.year, end.month, end.day);
    if (e.isBefore(s)) {
      final DateTime tmp = s;
      s = e;
      e = tmp;
    }

    // Batch writes are limited; chunk to stay safe.
    const int maxWritesPerBatch = 450;
    int pending = 0;
    WriteBatch batch = _firestore.batch();

    DateTime cursor = s;
    while (!cursor.isAfter(e)) {
      final String key = AttendanceCalendarDay.dateKeyFor(cursor);
      final DocumentReference<Map<String, dynamic>> ref = _col.doc(key);
        batch.set(
      ref,
      <String, dynamic>{
        'type': type == AttendanceCalendarDayType.examWeek
          ? 'exam_week'
          : (type == AttendanceCalendarDayType.holiday
            ? 'holiday'
            : (type == AttendanceCalendarDayType.schoolActivity
              ? 'school_activity'
              : 'suspension')),
        'code': type == AttendanceCalendarDayType.examWeek
          ? 'Ex'
          : (type == AttendanceCalendarDayType.holiday
            ? 'H'
            : (type == AttendanceCalendarDayType.schoolActivity
              ? 'A'
              : 'S')),
        'label': type == AttendanceCalendarDayType.examWeek
          ? 'Exam Week'
          : (type == AttendanceCalendarDayType.holiday
            ? 'Holiday'
            : (type == AttendanceCalendarDayType.schoolActivity
              ? 'School Activity'
              : 'Class Suspension')),
          if ((reason ?? '').trim().isNotEmpty) 'reason': reason!.trim(),
          'dateKey': key,
          'updatedAt': FieldValue.serverTimestamp(),
          'createdAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );
      pending++;
      if (pending >= maxWritesPerBatch) {
        await batch.commit();
        batch = _firestore.batch();
        pending = 0;
      }

      cursor = cursor.add(const Duration(days: 1));
    }

    if (pending > 0) {
      await batch.commit();
    }
  }

  Future<void> deleteDay({
    required DateTime day,
  }) async {
    final String key = AttendanceCalendarDay.dateKeyFor(day);
    await _col.doc(key).delete();
  }
}
