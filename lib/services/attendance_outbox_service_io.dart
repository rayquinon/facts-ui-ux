import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:path_provider/path_provider.dart';

class AttendanceOutboxService {
  AttendanceOutboxService._();

  static final AttendanceOutboxService instance = AttendanceOutboxService._();

  static const String _dirName = 'attendance_outbox';

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  bool _flushing = false;
  
  Future<int> pendingCountBestEffort() async {
    try {
      final Directory dir = await _outboxDir();
      if (!dir.existsSync()) return 0;
      final List<FileSystemEntity> entities = dir.listSync(followLinks: false);
      return entities.whereType<File>().length;
    } catch (_) {
      return 0;
    }
  }

  Future<Directory> _outboxDir() async {
    final Directory base = await getApplicationSupportDirectory();
    final Directory dir = Directory('${base.path}${Platform.pathSeparator}$_dirName');
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  String _randomSuffix() {
    final int n = math.Random.secure().nextInt(1 << 32);
    return n.toRadixString(16).padLeft(8, '0');
  }

  Future<void> _enqueue(Map<String, Object?> payload) async {
    try {
      final Directory dir = await _outboxDir();
      final int ms = DateTime.now().toUtc().millisecondsSinceEpoch;
      final String name = 'op_${ms}_${_randomSuffix()}.json';
      final File file = File('${dir.path}${Platform.pathSeparator}$name');
      await file.writeAsString(jsonEncode(payload), flush: true);
    } catch (_) {
      // Best-effort only.
    }
  }

  Future<void> enqueueCapture({
    required String sessionId,
    required String captureId,
    required String capturedAtLocalIso,
    required String? matchUserId,
    required String? matchDisplayName,
    required double? confidence,
    required double? similarity,
    required List<double> embedding,
    required String? attendanceStatus,
  }) async {
    await _enqueue(<String, Object?>{
      'type': 'capture',
      'sessionId': sessionId,
      'captureId': captureId,
      'capturedAtLocalIso': capturedAtLocalIso,
      'matchUserId': matchUserId,
      'matchDisplayName': matchDisplayName,
      'confidence': confidence,
      'similarity': similarity,
      'embedding': embedding,
      'attendanceStatus': attendanceStatus,
    });
  }

  Future<void> enqueueAttendeeUpsert({
    required String sessionId,
    required String studentId,
    required String displayName,
    required bool isFirstStatusForStudent,
    required String capturedAtLocalIso,
    required double? confidence,
    required String? status,
    required int? minutesLate,
    required int? minutesAbsent,
  }) async {
    await _enqueue(<String, Object?>{
      'type': 'attendee',
      'sessionId': sessionId,
      'studentId': studentId,
      'displayName': displayName,
      'isFirstStatusForStudent': isFirstStatusForStudent,
      'capturedAtLocalIso': capturedAtLocalIso,
      'confidence': confidence,
      'status': status,
      'minutesLate': minutesLate,
      'minutesAbsent': minutesAbsent,
    });
  }

  Future<void> enqueueSessionLastCaptureAt({required String sessionId}) async {
    await _enqueue(<String, Object?>{
      'type': 'session_lastCaptureAt',
      'sessionId': sessionId,
    });
  }

  Future<void> flushBestEffort() async {
    if (_flushing) return;
    _flushing = true;
    try {
      final User? user = FirebaseAuth.instance.currentUser;
      if (user == null) return;

      final Directory dir = await _outboxDir();
      if (!dir.existsSync()) return;

      final List<FileSystemEntity> entities = dir.listSync(followLinks: false);
      final List<File> files = entities.whereType<File>().toList(growable: false)
        ..sort((a, b) => a.path.compareTo(b.path));

      for (final File file in files) {
        Map<String, Object?>? payload;
        try {
          final String raw = await file.readAsString();
          final Object? decoded = jsonDecode(raw);
          if (decoded is Map) {
            payload = decoded.cast<String, Object?>();
          }
        } catch (_) {
          // Malformed file; delete it.
          try {
            await file.delete();
          } catch (_) {}
          continue;
        }
        if (payload == null) continue;

        final String type = (payload['type'] ?? '').toString();
        final String sessionId = (payload['sessionId'] ?? '').toString().trim();
        if (sessionId.isEmpty) {
          try {
            await file.delete();
          } catch (_) {}
          continue;
        }

        try {
          final DocumentReference<Map<String, dynamic>> sessionRef = _firestore
              .collection('attendanceSessions')
              .doc(sessionId);

          if (type == 'capture') {
            final String captureId = (payload['captureId'] ?? '').toString().trim();
            final String capturedAtLocalIso = (payload['capturedAtLocalIso'] ?? '').toString();
            final String? matchUserId = (payload['matchUserId'] as String?)?.trim();
            final String? matchDisplayName = (payload['matchDisplayName'] as String?)?.trim();
            final double? confidence = payload['confidence'] is num
                ? (payload['confidence'] as num).toDouble()
                : null;
            final double? similarity = payload['similarity'] is num
                ? (payload['similarity'] as num).toDouble()
                : null;
            final String? attendanceStatus = (payload['attendanceStatus'] as String?)?.trim();

            final List<double> embedding = (payload['embedding'] is List)
                ? (payload['embedding'] as List)
                    .whereType<num>()
                    .map((n) => n.toDouble())
                    .toList(growable: false)
                : <double>[];

            if (captureId.isEmpty) {
              throw StateError('Missing captureId');
            }

            await sessionRef.collection('captures').doc(captureId).set(<String, dynamic>{
              'clientCaptureId': captureId,
              'capturedAt': FieldValue.serverTimestamp(),
              'capturedAtLocal': capturedAtLocalIso,
              'matchUserId': matchUserId,
              'matchDisplayName': matchDisplayName,
              'confidence': confidence,
              'similarity': similarity,
              'embedding': embedding,
              'attendanceStatus': attendanceStatus,
            }, SetOptions(merge: true));
          } else if (type == 'attendee') {
            final String studentId = (payload['studentId'] ?? '').toString().trim();
            final String displayName = (payload['displayName'] ?? '').toString();
            final bool isFirst = payload['isFirstStatusForStudent'] == true;
            final String capturedAtLocalIso = (payload['capturedAtLocalIso'] ?? '').toString();
            final double? confidence = payload['confidence'] is num
                ? (payload['confidence'] as num).toDouble()
                : null;
            final String? status = (payload['status'] as String?)?.trim();
            final int? minutesLate = payload['minutesLate'] is num
                ? (payload['minutesLate'] as num).round()
                : null;
            final int? minutesAbsent = payload['minutesAbsent'] is num
                ? (payload['minutesAbsent'] as num).round()
                : null;

            if (studentId.isEmpty) {
              throw StateError('Missing studentId');
            }

            await sessionRef.collection('attendees').doc(studentId).set(<String, dynamic>{
              'displayName': displayName,
              if (isFirst) 'firstCapturedAt': FieldValue.serverTimestamp(),
              if (isFirst) 'firstCapturedAtLocal': capturedAtLocalIso,
              'lastCapturedAt': FieldValue.serverTimestamp(),
              if (confidence != null) 'confidence': confidence,
              if (isFirst && status != null && status.isNotEmpty) 'status': status,
              if (isFirst) 'statusComputedAt': FieldValue.serverTimestamp(),
              if (isFirst && minutesLate != null) 'minutesLate': minutesLate,
              if (isFirst && minutesAbsent != null) 'minutesAbsent': minutesAbsent,
            }, SetOptions(merge: true));
          } else if (type == 'session_lastCaptureAt') {
            await sessionRef.set(<String, dynamic>{
              'lastCaptureAt': FieldValue.serverTimestamp(),
            }, SetOptions(merge: true));
          } else {
            // Unknown op type; delete.
          }

          // If we got here, op is done; delete the file.
          try {
            await file.delete();
          } catch (_) {
            // ignore
          }
        } on FirebaseException catch (e) {
          // If we're offline/unavailable, stop early.
          final String code = e.code;
          if (code == 'unavailable' || code == 'network-request-failed') {
            return;
          }
          // If this is an auth/permission issue, keep the op and retry later
          // (e.g. after re-auth / refreshed custom claims).
          if (code == 'permission-denied' || code == 'unauthenticated') {
            return;
          }
          // For truly invalid ops (bad data, missing docs), drop to avoid wedging.
          try {
            await file.delete();
          } catch (_) {}
        } catch (_) {
          // Unknown error: stop to avoid thrash; keep file for later.
          return;
        }
      }
    } finally {
      _flushing = false;
    }
  }

  /// Return pending outbox payloads for [sessionId]. Best-effort only.
  Future<List<Map<String, Object?>>> pendingOperationsForSession(
      String sessionId) async {
    try {
      final Directory dir = await _outboxDir();
      if (!dir.existsSync()) return <Map<String, Object?>>[];
      final List<FileSystemEntity> entities =
          dir.listSync(followLinks: false);
      final List<File> files = entities.whereType<File>().toList(growable: false)
        ..sort((a, b) => a.path.compareTo(b.path));

      final List<Map<String, Object?>> results = <Map<String, Object?>>[];
      for (final File file in files) {
        try {
          final String raw = await file.readAsString();
          final Object? decoded = jsonDecode(raw);
          if (decoded is Map) {
            final Map<String, Object?> payload = decoded.cast<String, Object?>();
            final String sid = (payload['sessionId'] ?? '').toString().trim();
            if (sid == sessionId) {
              results.add(payload);
            }
          }
        } catch (_) {
          // ignore malformed files for read-only probing
        }
      }
      return results;
    } catch (_) {
      return <Map<String, Object?>>[];
    }
  }
}
