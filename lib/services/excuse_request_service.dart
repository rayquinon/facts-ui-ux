import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';

class ExcuseRequestService {
  ExcuseRequestService({
    FirebaseAuth? auth,
    FirebaseFirestore? firestore,
    FirebaseFunctions? functions,
    String functionsRegion = 'us-central1',
    FirebaseStorage? storage,
  })  : _auth = auth ?? FirebaseAuth.instance,
        _firestore = firestore ?? FirebaseFirestore.instance,
        _functions = functions ?? FirebaseFunctions.instanceFor(region: functionsRegion),
        _storage = storage ?? FirebaseStorage.instance;

  final FirebaseAuth _auth;
  final FirebaseFirestore _firestore;
  final FirebaseFunctions _functions;
  final FirebaseStorage _storage;

  User get _user {
    final User? user = _auth.currentUser;
    if (user == null) {
      throw StateError('Not signed in');
    }
    return user;
  }

  Future<CreateExcuseRequestResult> create({
    required String reason,
    required List<Map<String, Object?>> entries,
  }) async {
    final HttpsCallable callable = _functions.httpsCallable('createExcuseRequest');
    try {
      final HttpsCallableResult<dynamic> result =
          await callable.call(<String, Object?>{
        'reason': reason,
        'entries': entries,
      });

      final Map<String, dynamic> data =
          (result.data as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
      final bool ok = data['ok'] == true;
      if (!ok) {
        throw StateError('Create request failed');
      }

      final String requestId = (data['requestId'] as String?) ?? '';
      final String uploadPath = (data['uploadPath'] as String?) ?? '';
      if (requestId.isEmpty || uploadPath.isEmpty) {
        throw StateError('Create request returned invalid data');
      }

      return CreateExcuseRequestResult(
        requestId: requestId,
        uploadPath: uploadPath,
      );
    } on FirebaseFunctionsException catch (e) {
      if (e.code.toLowerCase() == 'not-found') {
        throw StateError(
          'Cloud Function createExcuseRequest was not found. '
          'Deploy functions (`firebase deploy --only functions`) and ensure the region matches (default: us-central1). '
          'Details: ${e.message ?? e.toString()}',
        );
      }
      rethrow;
    }
  }

  Future<void> uploadPdf({
    required String uploadPath,
    required String fileName,
    required Uint8List bytes,
  }) async {
    final Reference ref = _storage.ref(uploadPath);
    await ref.putData(
      bytes,
      SettableMetadata(contentType: 'application/pdf', customMetadata: <String, String>{
        'originalFileName': fileName,
        'uploadedBy': _user.uid,
      }),
    );
  }

  Future<void> attachMetadata({
    required String requestId,
    required String path,
    required String fileName,
    required int size,
  }) async {
    await _firestore.collection('excuseRequests').doc(requestId).set(
      <String, Object?>{
        'attachment': <String, Object?>{
          'path': path,
          'fileName': fileName,
          'size': size,
          'contentType': 'application/pdf',
          'uploadedAt': FieldValue.serverTimestamp(),
        },
        'updatedAt': FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
  }

  Future<void> approve({required String requestId}) async {
    final HttpsCallable callable = _functions.httpsCallable('approveExcuseRequest');
    await callable.call(<String, Object?>{'requestId': requestId});
  }

  Future<void> disapprove({required String requestId}) async {
    final HttpsCallable callable = _functions.httpsCallable('disapproveExcuseRequest');
    await callable.call(<String, Object?>{'requestId': requestId});
  }

  Future<void> delete({required String requestId}) async {
    final HttpsCallable callable = _functions.httpsCallable('deleteExcuseRequest');
    await callable.call(<String, Object?>{'requestId': requestId});
  }

  Future<Uint8List> downloadPdfBytes({
    required String path,
    int maxSizeBytes = 10 * 1024 * 1024,
  }) async {
    final Uint8List? data = await _storage.ref(path).getData(maxSizeBytes);
    if (data == null || data.isEmpty) {
      throw StateError('Unable to download PDF');
    }
    return data;
  }
}

class CreateExcuseRequestResult {
  const CreateExcuseRequestResult({required this.requestId, required this.uploadPath});

  final String requestId;
  final String uploadPath;
}
