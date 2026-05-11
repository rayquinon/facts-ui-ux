import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// Service for diagnosing authentication and admin status issues
class AuthDiagnosticService {
  static final AuthDiagnosticService _instance = AuthDiagnosticService._internal();

  factory AuthDiagnosticService() {
    return _instance;
  }

  AuthDiagnosticService._internal();

  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFunctions _functions = FirebaseFunctions.instance;

  /// Check if the current user has admin privileges
  Future<Map<String, dynamic>> checkAdminStatus() async {
    try {
      final User? currentUser = _auth.currentUser;
      
      if (currentUser == null) {
        return {
          'authenticated': false,
          'uid': null,
          'email': null,
          'isAdmin': false,
          'error': 'No user logged in',
        };
      }

      // Refresh the token to get latest claims
      final IdTokenResult tokenResult = await currentUser.getIdTokenResult(true);
      
      final Map<String, dynamic> claims = tokenResult.claims ?? {};
      final bool hasAdminClaim = claims['admin'] == true || claims['admin'] == 'true';

      debugPrint('Auth diagnostic:');
      debugPrint('  UID: ${currentUser.uid}');
      debugPrint('  Email: ${currentUser.email}');
      debugPrint('  Display Name: ${currentUser.displayName}');
      debugPrint('  Has admin claim: $hasAdminClaim');
      debugPrint('  All claims: $claims');

      return {
        'authenticated': true,
        'uid': currentUser.uid,
        'email': currentUser.email,
        'displayName': currentUser.displayName,
        'isAdmin': hasAdminClaim,
        'claims': claims,
        'error': hasAdminClaim ? null : 'User does not have admin claim',
      };
    } catch (e, st) {
      debugPrint('Failed to check admin status: $e\n$st');
      return {
        'authenticated': false,
        'isAdmin': false,
        'error': e.toString(),
      };
    }
  }

  /// Test the Cloud Function accessibility
  Future<Map<String, dynamic>> testCloudFunctionAccess() async {
    try {
      final HttpsCallable callable =
          _functions.httpsCallable('adminBulkCreateStudentAccounts');

      final HttpsCallableResult response = await callable.call({
        'students': [], // Empty array to just test auth
      });

      return {
        'success': true,
        'message': 'Cloud Function is accessible',
        'response': response.data,
      };
    } on FirebaseFunctionsException catch (e) {
      return {
        'success': false,
        'code': e.code,
        'message': e.message,
        'error': 'Cloud Function returned error',
      };
    } catch (e) {
      return {
        'success': false,
        'error': e.toString(),
      };
    }
  }
}
