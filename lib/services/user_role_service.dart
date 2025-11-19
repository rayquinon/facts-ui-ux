import 'package:cloud_firestore/cloud_firestore.dart';

class UserRoleService {
  const UserRoleService._();

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
}
