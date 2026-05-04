import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import 'attendance_outbox_service.dart';

/// Automatically flush the attendance outbox when network connectivity
/// is (re)established. Best-effort only.
class OutboxAutoSync {
  OutboxAutoSync._();

  static final OutboxAutoSync instance = OutboxAutoSync._();

  StreamSubscription<ConnectivityResult>? _sub;
  Timer? _debounce;
  bool _enabled = false;

  final Duration _debounceDuration = const Duration(seconds: 2);

  void enable() {
    if (_enabled) return;
    _enabled = true;
    try {
      _sub = Connectivity().onConnectivityChanged.listen(_onConnectivityChanged);
      // Immediately check current state and schedule a flush if online.
      Connectivity().checkConnectivity().then((ConnectivityResult r) {
        if (!_enabled) return;
        if (r != ConnectivityResult.none) {
          _scheduleFlush('initial');
        }
      });
    } catch (e) {
      if (kDebugMode) debugPrint('OutboxAutoSync: enable failed: $e');
    }
  }

  void disable() {
    if (!_enabled) return;
    _enabled = false;
    _sub?.cancel();
    _sub = null;
    _debounce?.cancel();
    _debounce = null;
  }

  void _onConnectivityChanged(ConnectivityResult result) {
    if (!_enabled) return;
    if (result == ConnectivityResult.none) {
      if (kDebugMode) debugPrint('OutboxAutoSync: offline');
      return;
    }
    _scheduleFlush('connectivity:${result.name}');
  }

  void _scheduleFlush(String reason) {
    _debounce?.cancel();
    _debounce = Timer(_debounceDuration, () async {
      try {
        final User? user = FirebaseAuth.instance.currentUser;
        if (user == null) {
          if (kDebugMode) debugPrint('OutboxAutoSync: no user, skipping flush');
          return;
        }
        if (kDebugMode) debugPrint('OutboxAutoSync: flushing due to $reason');
        await AttendanceOutboxService.instance.flushBestEffort();
      } catch (e) {
        if (kDebugMode) debugPrint('OutboxAutoSync: flush failed: $e');
      }
    });
  }
}
