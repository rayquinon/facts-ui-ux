import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
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

  Future<void> _debugLog(String message) async {
    try {
      final Directory dir = await _outboxDir();
      final File log = File('${dir.path}${Platform.pathSeparator}outbox_debug.log');
      final String line = '${DateTime.now().toUtc().toIso8601String()} $message\n';
      await log.writeAsString(line, mode: FileMode.append, flush: true);
    } catch (_) {
      // Best-effort diagnostics only.
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
      unawaited(_debugLog('enqueued file=$name type=${payload['type'] ?? 'unknown'} session=${payload['sessionId'] ?? ''}'));
    } catch (e) {
      unawaited(_debugLog('enqueue failed: $e'));
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
      unawaited(_debugLog('flushBestEffort: started'));
      final User? user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        unawaited(_debugLog('flushBestEffort: aborted - no authenticated user'));
        return;
      }

      final Directory dir = await _outboxDir();
      if (!dir.existsSync()) {
        unawaited(_debugLog('flushBestEffort: outbox dir does not exist'));
        return;
      }

      final List<FileSystemEntity> entities = dir.listSync(followLinks: false);
      final List<File> files = entities.whereType<File>().toList(growable: false)
        ..sort((a, b) => a.path.compareTo(b.path));

      unawaited(_debugLog('flushBestEffort: found ${files.length} files'));

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
            unawaited(_debugLog('flushBestEffort: deleted malformed file ${file.path}'));
          } catch (e) {
            unawaited(_debugLog('flushBestEffort: failed deleting malformed file ${file.path}: $e'));
          }
          continue;
        }
        if (payload == null) continue;

        final String type = (payload['type'] ?? '').toString();
        final String sessionId = (payload['sessionId'] ?? '').toString().trim();
        unawaited(_debugLog('flushBestEffort: processing file=${file.path} type=$type session=$sessionId'));
        if (sessionId.isEmpty) {
          try {
            await file.delete();
            unawaited(_debugLog('flushBestEffort: deleted file with empty session ${file.path}'));
          } catch (_) {}
          continue;
        }

        try {
          final DocumentReference<Map<String, dynamic>> sessionRef = _firestore
              .collection('attendanceSessions')
              .doc(sessionId);

          // Attempt the operation with a small retry/backoff for transient
          // network/server unavailability errors. For auth/permission errors
          // we bail so the op can be retried after re-auth.
          const int maxAttempts = 3;
          bool opCompleted = false;
          for (int attempt = 1; attempt <= maxAttempts && !opCompleted; attempt++) {
            try {
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

              // Success for this op.
              try {
                await file.delete();
                unawaited(_debugLog('flushBestEffort: op success deleted file ${file.path}'));
              } catch (_) {}
              opCompleted = true;
            } on FirebaseException catch (e) {
              unawaited(_debugLog('flushBestEffort: firebase exception code=${e.code} message=${e.message}'));
              final String code = e.code;
              // Auth/permission issues: keep the op for retry later.
              if (code == 'permission-denied' || code == 'unauthenticated') {
                unawaited(_debugLog('flushBestEffort: aborting flush due to auth/permission error: $code'));
                return;
              }
              // Transient network/server unavailability: retry a few times,
              // then stop flushing to avoid thrash.
              if (code == 'unavailable' || code == 'network-request-failed' || code == 'deadline-exceeded') {
                if (attempt >= maxAttempts) {
                  return;
                }
                // Exponential backoff.
                final int backoffMs = 200 * (1 << (attempt - 1));
                await Future.delayed(Duration(milliseconds: backoffMs));
                continue;
              }
              // For truly invalid ops (bad data, missing docs), drop to avoid wedging.
              try {
                await file.delete();
                unawaited(_debugLog('flushBestEffort: deleted invalid op file ${file.path}'));
              } catch (_) {}
              opCompleted = true;
            } catch (_) {
              // Unknown error: stop to avoid thrash; keep file for later.
              unawaited(_debugLog('flushBestEffort: unknown error during op processing, aborting'));
              return;
            }
          }
        } catch (_) {
          // Protect outer loop: unknown failures should stop flushing.
          unawaited(_debugLog('flushBestEffort: outer loop error, aborting'));
          return;
        }
      }
    } finally {
      unawaited(_debugLog('flushBestEffort: completed'));
      _flushing = false;
    }
  }

  /// Return pending outbox payloads for [sessionId]. Best-effort only.
  Future<List<Map<String, Object?>>> pendingOperationsForSession(
      String sessionId,
      {bool fuzzy = false}) async {
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
            if (!fuzzy) {
              if (sid == sessionId) {
                results.add(payload);
              }
            } else {
              if (sid == sessionId) {
                results.add(payload);
              } else {
                // Fuzzy match: compare the canonical session id parts
                // Format: sess_{instructorId}_{classId}_{dateKey}_{scheduleKey}
                List<String> partsA = _sessionIdParts(sid);
                List<String> partsB = _sessionIdParts(sessionId);
                if (partsA.length >= 3 && partsB.length >= 3) {
                  if (partsA[0] == partsB[0] &&
                      partsA[1] == partsB[1] &&
                      partsA[2] == partsB[2]) {
                    results.add(payload);
                  }
                }
              }
            }
          }
        } catch (_) {
          // ignore malformed files for read-only probing
        }
      }
      if (fuzzy && results.isNotEmpty) {
        try {
          // Simple diagnostic aid during development.
          debugPrint('AttendanceOutboxService: fuzzy matched ${results.length} ops for sessionId $sessionId');
        } catch (_) {}
      }
      return results;
    } catch (_) {
      return <Map<String, Object?>>[];
    }
  }

  List<String> _sessionIdParts(String sid) {
    final String s = sid.trim();
    String work = s;
    if (work.startsWith('sess_')) {
      work = work.substring(5);
    }
    return work.split('_');
  }
}
