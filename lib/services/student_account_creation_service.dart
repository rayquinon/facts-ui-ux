import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

/// Model for a student account to be created
class StudentAccountCreationRequest {
  StudentAccountCreationRequest({
    required this.email,
    required this.displayName,
    required this.studentId,
    required this.section,
    required this.password,
    this.phoneNumber,
  });

  final String email;
  final String displayName;
  final String studentId;
  final String section;
  final String password;
  final String? phoneNumber;

  /// Convert to a map for Firebase function call
  Map<String, dynamic> toMap() => {
    'email': email,
    'displayName': displayName,
    'studentId': studentId,
    'section': section,
    'password': password,
    if (phoneNumber != null && phoneNumber!.trim().isNotEmpty)
      'phoneNumber': phoneNumber!.trim(),
  };
}

/// Model for a successfully created account
class CreatedStudentAccount {
  CreatedStudentAccount({
    required this.email,
    required this.uid,
    required this.studentId,
    this.status = 'created',
  });

  final String email;
  final String uid;
  final String studentId;
  final String status; // 'created' or 'already-exists'

  /// Create from Firebase response
  factory CreatedStudentAccount.fromMap(Map<String, dynamic> data) {
    return CreatedStudentAccount(
      email: data['email'] as String? ?? '',
      uid: data['uid'] as String? ?? '',
      studentId: data['studentId'] as String? ?? '',
      status: data['status'] as String? ?? 'created',
    );
  }
}

/// Model for a failed account creation
class FailedStudentAccount {
  FailedStudentAccount({
    required this.email,
    required this.studentId,
    required this.error,
  });

  final String email;
  final String studentId;
  final String error;

  /// Create from Firebase response
  factory FailedStudentAccount.fromMap(Map<String, dynamic> data) {
    return FailedStudentAccount(
      email: data['email'] as String? ?? '',
      studentId: data['studentId'] as String? ?? '',
      error: data['error'] as String? ?? 'Unknown error',
    );
  }
}

/// Response from bulk account creation
class BulkAccountCreationResponse {
  BulkAccountCreationResponse({
    required this.ok,
    required this.created,
    required this.failed,
  });

  final bool ok;
  final List<CreatedStudentAccount> created;
  final List<FailedStudentAccount> failed;

  int get createdCount => created.length;
  int get failedCount => failed.length;

  /// Create from Firebase response
  factory BulkAccountCreationResponse.fromMap(Map<String, dynamic> data) {
    final List<dynamic> createdRaw = data['created'] as List<dynamic>? ?? [];
    final List<dynamic> failedRaw = data['failed'] as List<dynamic>? ?? [];

    return BulkAccountCreationResponse(
      ok: data['ok'] == true,
      created: createdRaw
          .cast<Map<String, dynamic>>()
          .map(CreatedStudentAccount.fromMap)
          .toList(),
      failed: failedRaw
          .cast<Map<String, dynamic>>()
          .map(FailedStudentAccount.fromMap)
          .toList(),
    );
  }
}

/// Service for creating student accounts in bulk
class StudentAccountCreationService {
  static final StudentAccountCreationService _instance =
      StudentAccountCreationService._internal();

  factory StudentAccountCreationService() {
    return _instance;
  }

  StudentAccountCreationService._internal();

  final FirebaseFunctions _functions = FirebaseFunctions.instance;

  /// Bulk create student accounts from CSV import data
  ///
  /// This calls the Firebase Cloud Function `adminBulkCreateStudentAccounts`
  /// which requires admin authentication.
  ///
  /// Each student's password will be set to their studentId by default.
  ///
  /// Throws if the operation fails or admin auth is missing.
  Future<BulkAccountCreationResponse> bulkCreateStudentAccounts({
    required List<StudentAccountCreationRequest> students,
  }) async {
    if (students.isEmpty) {
      throw ArgumentError('students list cannot be empty');
    }

    try {
      debugPrint('Calling adminBulkCreateStudentAccounts with ${students.length} students');
      
      final HttpsCallable callable =
          _functions.httpsCallable('adminBulkCreateStudentAccounts');

      final Map<String, dynamic> payload = {
        'students': students.map((s) => s.toMap()).toList(),
      };
      debugPrint('Payload: ${students.map((s) => '${s.email}/${s.studentId}').join(', ')}');

      final HttpsCallableResult response = await callable.call(payload);

      final Map<String, dynamic> data =
          response.data as Map<String, dynamic>? ?? {};
      
      debugPrint('Response ok: ${data['ok']}, created: ${(data['created'] as List?)?.length ?? 0}, failed: ${(data['failed'] as List?)?.length ?? 0}');
      
      if (data['failed'] != null && (data['failed'] as List).isNotEmpty) {
        final List<dynamic> failures = data['failed'] as List;
        for (final dynamic f in failures) {
          if (f is Map<String, dynamic>) {
            debugPrint('  Failed: ${f['email']} - ${f['error']}');
          }
        }
      }

      return BulkAccountCreationResponse.fromMap(data);
    } on FirebaseFunctionsException catch (e) {
      debugPrint('Firebase function exception: code=${e.code}, message=${e.message}');
      debugPrint('Full error details: $e');
      rethrow;
    } catch (e, st) {
      debugPrint('Bulk account creation failed: $e');
      debugPrint('Stack trace: $st');
      rethrow;
    }
  }
}
