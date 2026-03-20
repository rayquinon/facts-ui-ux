import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

bool _initialized = false;

String _normalizeTopicPart(String raw) {
  final String v = raw.trim().toLowerCase();
  final String collapsed = v.replaceAll(RegExp(r'\s+'), '_');
  return collapsed.replaceAll(RegExp(r'[^a-z0-9_\-]'), '');
}

Future<void> initPushNotifications({
  required String uid,
  required String role,
  String? section,
}) async {
  if (_initialized) {
    await updatePushSubscriptions(uid: uid, role: role, section: section);
    return;
  }
  _initialized = true;

  if (kIsWeb) return;

  if (!(Platform.isAndroid || Platform.isIOS || Platform.isMacOS)) {
    return;
  }

  final FirebaseMessaging messaging = FirebaseMessaging.instance;

  try {
    await messaging.requestPermission();
  } catch (_) {
    // Best-effort.
  }

  try {
    final String? token = await messaging.getToken();
    if (token != null && token.trim().isNotEmpty) {
      await _upsertToken(uid: uid, token: token.trim());
    }
  } catch (_) {
    // Best-effort.
  }

  // Subscribe after token retrieval; FCM will handle when token rotates.
  await updatePushSubscriptions(uid: uid, role: role, section: section);

  FirebaseMessaging.instance.onTokenRefresh.listen((String token) async {
    final String trimmed = token.trim();
    if (trimmed.isEmpty) return;
    try {
      await _upsertToken(uid: uid, token: trimmed);
    } catch (_) {
      // Best-effort.
    }
  });
}

Future<void> updatePushSubscriptions({
  required String uid,
  required String role,
  String? section,
}) async {
  if (kIsWeb) return;

  if (!(Platform.isAndroid || Platform.isIOS || Platform.isMacOS)) {
    return;
  }

  final FirebaseMessaging messaging = FirebaseMessaging.instance;

  final String userTopic = 'user_${_normalizeTopicPart(uid)}';
  try {
    await messaging.subscribeToTopic(userTopic);
  } catch (_) {
    // Best-effort.
  }

  final String normalizedRole = role.trim().toLowerCase();
  final String normalizedSection = (section ?? '').trim();
  if (normalizedRole == 'student' && normalizedSection.isNotEmpty) {
    final String sectionTopic = 'section_${_normalizeTopicPart(normalizedSection)}';
    try {
      await messaging.subscribeToTopic(sectionTopic);
    } catch (_) {
      // Best-effort.
    }
  }
}

Future<void> _upsertToken({required String uid, required String token}) async {
  final DocumentReference<Map<String, dynamic>> ref = FirebaseFirestore.instance
      .collection('users')
      .doc(uid)
      .collection('fcmTokens')
      .doc(token);

  await ref.set(<String, dynamic>{
    'token': token,
    'platform': Platform.operatingSystem,
    'updatedAt': FieldValue.serverTimestamp(),
    'lastSeenAt': FieldValue.serverTimestamp(),
    'createdAt': FieldValue.serverTimestamp(),
  }, SetOptions(merge: true));
}
