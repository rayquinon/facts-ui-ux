import 'package:cloud_firestore/cloud_firestore.dart';

class UserRoleService {
  const UserRoleService._();

  static const String _studentIdIndexCollection = 'studentIdIndex';
  static final Map<String, String?> _roleCache = <String, String?>{};

  static String normalizeStudentId(String raw) => raw.trim().toUpperCase();

  static String? _inferRoleFromProfile(Map<String, dynamic>? data) {
    if (data == null) return null;

    final Object? section = data['section'];
    if (section is String && section.trim().isNotEmpty) {
      return 'student';
    }

    final Object? studentId = data['studentId'] ?? data['Student ID'];
    if (studentId is String && studentId.trim().isNotEmpty) {
      return 'student';
    }

    final Object? department =
        data['Department'] ??
        data['department'] ??
        data['departmentName'] ??
        data['Department Name'] ??
        data['dept'] ??
        data['Dept'];
    if (department is String && department.trim().isNotEmpty) {
      return 'instructor';
    }

    final Object? approved = data['approved'];
    if (approved is bool) {
      return 'instructor';
    }

    return null;
  }

  static Future<String?> fetchRoleByUid(
    String? uid, {
    bool forceRefresh = false,
    bool attemptRepairIfMissing = false,
  }) async {
    if (uid == null) return null;

    // Only trust cached *non-null* roles. A missing role can be repaired later
    // (or set by an admin), and caching null would make that change invisible
    // until callers explicitly force-refresh.
    if (!forceRefresh && _roleCache.containsKey(uid)) {
      final String? cached = _roleCache[uid];
      if (cached != null) {
        return cached;
      }
    }

    final DocumentReference<Map<String, dynamic>> ref = FirebaseFirestore
        .instance
        .collection('users')
        .doc(uid);
    final DocumentSnapshot<Map<String, dynamic>> snapshot = await ref.get();
    final Map<String, dynamic>? data = snapshot.data();
    final Object? roleValue = data?['role'];
    if (roleValue is String) {
      final String role = roleValue.toLowerCase();
      _roleCache[uid] = role;
      return role;
    }

    if (attemptRepairIfMissing) {
      final String? inferred = _inferRoleFromProfile(data);
      if (inferred != null) {
        try {
          await ref.set(<String, dynamic>{
            'role': inferred,
          }, SetOptions(merge: true));
          _roleCache[uid] = inferred;
          return inferred;
        } on FirebaseException {
          // Best-effort: if rules disallow it, fall through.
        }
      }
    }

    return null;
  }

  /// Creates/updates a student profile while claiming a unique Student ID.
  ///
  /// This uses a batched write (no reads) so it works with security rules that
  /// keep the index private (students cannot read `studentIdIndex`). Uniqueness
  /// is enforced by Firestore rules using `!exists(...)` on the index document.
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

    final Map<String, dynamic> mergedProfile = <String, dynamic>{
      ...profile,
      'studentId': normalizedId,
      'Student ID': normalizedId,
    };

    final WriteBatch batch = firestore.batch();
    batch.set(userRef, mergedProfile, SetOptions(merge: true));
    batch.set(indexRef, <String, dynamic>{
      'uid': uid,
      'studentId': normalizedId,
      'createdAt': FieldValue.serverTimestamp(),
    });

    try {
      await batch.commit();
    } on FirebaseException catch (error) {
      // If the index doc already exists, rules will reject the create.
      if (error.code.toLowerCase().contains('permission')) {
        rethrow;
      }
      // Normalize common "already exists" shapes into a stable code that the
      // UI already handles.
      final String msg = (error.message ?? '').toLowerCase();
      if (error.code == 'already-exists' || msg.contains('already exists')) {
        throw FirebaseException(
          plugin: 'cloud_firestore',
          code: 'student-id-already-in-use',
          message: 'Student ID is already in use.',
        );
      }
      rethrow;
    }
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
