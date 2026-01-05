import 'package:cloud_firestore/cloud_firestore.dart';

class UserRoleService {
  const UserRoleService._();

  static const String _studentIdIndexCollection = 'studentIdIndex';

  static String normalizeStudentId(String raw) => raw.trim().toUpperCase();

  static Future<String?> fetchRoleByUid(String? uid) async {
    if (uid == null) return null;
    final DocumentSnapshot<Map<String, dynamic>> snapshot =
        await FirebaseFirestore.instance.collection('users').doc(uid).get();
    final Map<String, dynamic>? data = snapshot.data();
    final Object? roleValue = data?['role'];
    if (roleValue is String) {
      return roleValue.toLowerCase();
    }
    return null;
  }

  /// Creates/updates a student profile while claiming a unique Student ID.
  ///
  /// This uses a Firestore transaction to ensure the same Student ID can't be
  /// claimed by multiple users.
  static Future<void> upsertStudentProfileWithUniqueStudentId({
    required String uid,
    required String studentId,
    required Map<String, dynamic> profile,
  }) async {
    final String normalizedId = normalizeStudentId(studentId);
    if (normalizedId.isEmpty) {
      throw FirebaseException(
        plugin: 'cloud_firestore',
        code: 'invalid-student-id',
        message: 'Student ID is required.',
      );
    }
    final FirebaseFirestore firestore = FirebaseFirestore.instance;
    final DocumentReference<Map<String, dynamic>> userRef = firestore
        .collection('users')
        .doc(uid);
    final DocumentReference<Map<String, dynamic>> indexRef = firestore
        .collection(_studentIdIndexCollection)
        .doc(normalizedId);

    await firestore.runTransaction((Transaction tx) async {
      final DocumentSnapshot<Map<String, dynamic>> indexSnap = await tx.get(
        indexRef,
      );
      if (indexSnap.exists) {
        final String? existingUid = indexSnap.data()?['uid'] as String?;
        if (existingUid != null && existingUid != uid) {
          throw FirebaseException(
            plugin: 'cloud_firestore',
            code: 'student-id-already-in-use',
            message: 'Student ID is already in use.',
          );
        }
      }

      final Map<String, dynamic> mergedProfile = <String, dynamic>{
        ...profile,
        'studentId': normalizedId,
        'Student ID': normalizedId,
      };

      tx.set(userRef, mergedProfile, SetOptions(merge: true));
      tx.set(indexRef, <String, dynamic>{
        'uid': uid,
        'studentId': normalizedId,
        'createdAt': FieldValue.serverTimestamp(),
      });
    });
  }

  /// Admin-only helper: changes a user's Student ID while keeping the unique
  /// index in sync.
  static Future<void> adminSwapStudentId({
    required String uid,
    required String newStudentId,
    required String? oldStudentId,
    required Map<String, Object?> otherUpdates,
  }) async {
    final String normalizedNew = normalizeStudentId(newStudentId);
    if (normalizedNew.isEmpty) {
      throw FirebaseException(
        plugin: 'cloud_firestore',
        code: 'invalid-student-id',
        message: 'Student ID is required.',
      );
    }
    final String? normalizedOld =
        (oldStudentId == null || oldStudentId.trim().isEmpty)
        ? null
        : normalizeStudentId(oldStudentId);

    final FirebaseFirestore firestore = FirebaseFirestore.instance;
    final DocumentReference<Map<String, dynamic>> userRef = firestore
        .collection('users')
        .doc(uid);
    final DocumentReference<Map<String, dynamic>> newIndexRef = firestore
        .collection(_studentIdIndexCollection)
        .doc(normalizedNew);
    final DocumentReference<Map<String, dynamic>>? oldIndexRef =
        normalizedOld == null
        ? null
        : firestore.collection(_studentIdIndexCollection).doc(normalizedOld);

    await firestore.runTransaction((Transaction tx) async {
      final DocumentSnapshot<Map<String, dynamic>> newIndexSnap = await tx.get(
        newIndexRef,
      );
      if (newIndexSnap.exists) {
        final String? existingUid = newIndexSnap.data()?['uid'] as String?;
        if (existingUid != null && existingUid != uid) {
          throw FirebaseException(
            plugin: 'cloud_firestore',
            code: 'student-id-already-in-use',
            message: 'Student ID is already in use.',
          );
        }
      }

      if (oldIndexRef != null && normalizedOld != normalizedNew) {
        final DocumentSnapshot<Map<String, dynamic>> oldIndexSnap = await tx
            .get(oldIndexRef);
        if (oldIndexSnap.exists) {
          final String? oldUid = oldIndexSnap.data()?['uid'] as String?;
          if (oldUid == uid) {
            tx.delete(oldIndexRef);
          }
        }
      }

      tx.set(newIndexRef, <String, dynamic>{
        'uid': uid,
        'studentId': normalizedNew,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      tx.set(userRef, <String, Object?>{
        ...otherUpdates,
        'studentId': normalizedNew,
        'Student ID': normalizedNew,
      }, SetOptions(merge: true));
    });
  }
}
