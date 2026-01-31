import 'package:cloud_firestore/cloud_firestore.dart';

/// Firestore-backed metadata for the attendance report template header.
///
/// Stored at `settings/attendanceReportTemplate`.
class AttendanceReportTemplateMeta {
  const AttendanceReportTemplateMeta({
    required this.documentCodeNo,
    required this.revisionNo,
    required this.effectiveDate,
  });

  static const AttendanceReportTemplateMeta defaults =
      AttendanceReportTemplateMeta(
        documentCodeNo: 'FM-USTP-ACAD-06',
        revisionNo: '00',
        effectiveDate: '03.17.25',
      );

  static DocumentReference<Map<String, dynamic>> docRef(
    FirebaseFirestore firestore,
  ) => firestore.collection('settings').doc('attendanceReportTemplate');

  static AttendanceReportTemplateMeta fromData(Map<String, dynamic>? data) {
    if (data == null) return defaults;

    String readString(String key, String fallback) {
      final Object? value = data[key];
      if (value is! String) return fallback;
      final String trimmed = value.trim();
      return trimmed.isEmpty ? fallback : trimmed;
    }

    return AttendanceReportTemplateMeta(
      documentCodeNo: readString('documentCodeNo', defaults.documentCodeNo),
      revisionNo: readString('revisionNo', defaults.revisionNo),
      effectiveDate: readString('effectiveDate', defaults.effectiveDate),
    );
  }

  static Future<AttendanceReportTemplateMeta> fetch(
    FirebaseFirestore firestore,
  ) async {
    final DocumentSnapshot<Map<String, dynamic>> snapshot =
        await docRef(firestore).get();
    return fromData(snapshot.data());
  }

  final String documentCodeNo;
  final String revisionNo;
  final String effectiveDate;

  Map<String, dynamic> toFirestore() {
    return <String, dynamic>{
      'documentCodeNo': documentCodeNo.trim(),
      'revisionNo': revisionNo.trim(),
      'effectiveDate': effectiveDate.trim(),
      'updatedAt': FieldValue.serverTimestamp(),
    };
  }
}
