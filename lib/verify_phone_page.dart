import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'login.dart';
import 'widgets/confirm_sign_out_dialog.dart';

class VerifyPhonePage extends StatefulWidget {
  const VerifyPhonePage({
    super.key,
    required this.onVerified,
  });

  static const String routeName = '/verify-phone';

  final VoidCallback onVerified;

  @override
  State<VerifyPhonePage> createState() => _VerifyPhonePageState();
}

class _VerifyPhonePageState extends State<VerifyPhonePage> {
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _codeController = TextEditingController();

  bool _sending = false;
  bool _verifying = false;
  bool _codeSent = false;

  static const Duration _resendCooldown = Duration(minutes: 1);
  DateTime? _resendCooldownEndsAt;
  Timer? _resendCooldownTimer;

  String? _verificationId;
  int? _resendToken;
  String? _error;

  @override
  void dispose() {
    _resendCooldownTimer?.cancel();
    _phoneController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  bool get _supported => !kIsWeb;

  String _normalizePhone(String input) {
    final String value = input
        .trim()
        .replaceAll(' ', '')
        .replaceAll('-', '')
        .replaceAll('(', '')
        .replaceAll(')', '');

    // Accept common PH local formats and convert to E.164.
    // 09xxxxxxxxx (11 digits) -> +639xxxxxxxxx
    if (value.startsWith('09') && value.length == 11) {
      return '+63${value.substring(1)}';
    }
    // 9xxxxxxxxx (10 digits) -> +639xxxxxxxxx
    if (value.startsWith('9') && value.length == 10) {
      return '+63$value';
    }
    // 63xxxxxxxxxx -> +63xxxxxxxxxx
    if (RegExp(r'^63\d+$').hasMatch(value)) {
      return '+$value';
    }

    return value;
  }

  int get _resendCooldownSecondsRemaining {
    final DateTime? until = _resendCooldownEndsAt;
    if (until == null) return 0;
    final int seconds = until.difference(DateTime.now()).inSeconds;
    return seconds <= 0 ? 0 : seconds;
  }

  void _startResendCooldown() {
    _resendCooldownEndsAt = DateTime.now().add(_resendCooldown);
    _resendCooldownTimer?.cancel();
    _resendCooldownTimer = Timer.periodic(const Duration(seconds: 1), (Timer t) {
      if (!mounted) return;
      if (_resendCooldownSecondsRemaining <= 0) {
        t.cancel();
        setState(() {});
        return;
      }
      setState(() {});
    });
  }

  void _clearResendCooldown() {
    _resendCooldownEndsAt = null;
    _resendCooldownTimer?.cancel();
    _resendCooldownTimer = null;
  }

  Future<void> _sendCode({bool forceResend = false}) async {
    if (!_supported) return;
    final User? user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    if (_sending || _verifying) return;

    final int remaining = _resendCooldownSecondsRemaining;
    if (remaining > 0) {
      setState(() {
        _error = 'Please wait ${remaining}s before resending the code.';
      });
      return;
    }

    final String phone = _normalizePhone(_phoneController.text);
    if (phone.isEmpty) {
      setState(() => _error = 'Enter a phone number (include country code).');
      return;
    }

    setState(() {
      _sending = true;
      _error = null;
    });

    // Client-side rate limit to reduce accidental spamming.
    _startResendCooldown();

    final Completer<void> completer = Completer<void>();

    try {
      await FirebaseAuth.instance.verifyPhoneNumber(
        phoneNumber: phone,
        timeout: const Duration(seconds: 60),
        forceResendingToken: forceResend ? _resendToken : null,
        verificationCompleted: (PhoneAuthCredential credential) async {
          // Android may auto-resolve the SMS code.
          try {
            await FirebaseAuth.instance.currentUser?.linkWithCredential(
              credential,
            );
            await FirebaseAuth.instance.currentUser?.reload();
            if (!mounted) return;
            _clearResendCooldown();
            widget.onVerified();
          } on FirebaseAuthException catch (e) {
            if (!mounted) return;
            setState(() => _error = _mapAuthError(e));
          } finally {
            if (!completer.isCompleted) completer.complete();
          }
        },
        verificationFailed: (FirebaseAuthException e) {
          if (mounted) {
            setState(() => _error = _mapAuthError(e));
          }
          if (mounted) {
            // If the send failed, allow retry immediately.
            _clearResendCooldown();
          }
          if (!completer.isCompleted) completer.complete();
        },
        codeSent: (String verificationId, int? resendToken) {
          if (mounted) {
            setState(() {
              _verificationId = verificationId;
              _resendToken = resendToken;
              _codeSent = true;
              _error = null;
            });
          }
          if (!completer.isCompleted) completer.complete();
        },
        codeAutoRetrievalTimeout: (String verificationId) {
          if (mounted) {
            setState(() => _verificationId = verificationId);
          }
          if (!completer.isCompleted) completer.complete();
        },
      );
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Failed to send code. $e');
      }
      if (mounted) {
        _clearResendCooldown();
      }
      if (!completer.isCompleted) completer.complete();
    } finally {
      await completer.future;
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _verifyCode() async {
    if (!_supported) return;
    final User? user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    if (_verifying || _sending) return;

    final String verificationId = (_verificationId ?? '').trim();
    final String smsCode = _codeController.text.trim();
    if (verificationId.isEmpty || smsCode.isEmpty) {
      setState(() => _error = 'Enter the 6-digit code we sent to your phone.');
      return;
    }

    setState(() {
      _verifying = true;
      _error = null;
    });

    try {
      final PhoneAuthCredential credential = PhoneAuthProvider.credential(
        verificationId: verificationId,
        smsCode: smsCode,
      );
      await user.linkWithCredential(credential);
      await user.reload();
      if (!mounted) return;
      widget.onVerified();
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      setState(() => _error = _mapAuthError(e));
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Verification failed. Please try again.');
    } finally {
      if (mounted) setState(() => _verifying = false);
    }
  }

  String _mapAuthError(FirebaseAuthException e) {
    switch (e.code) {
      case 'operation-not-allowed':
        return 'Phone sign-in is disabled for this Firebase project. Enable it in Firebase Console → Authentication → Sign-in method → Phone.';
      case 'missing-client-identifier':
        return 'Phone verification could not identify this Android app. In Firebase Console → Project settings → Your apps (Android), add your app\'s SHA-1 and SHA-256 certificate fingerprints (for the release keystore), then download a fresh google-services.json and rebuild the APK.';
      case 'app-not-authorized':
        return 'This app is not authorized to use Firebase Auth. Verify your Android package name matches in Firebase and re-download google-services.json.';
      case 'invalid-app-credential':
        return 'App verification failed. Ensure Google Play services are available/updated on the device and your SHA-1/SHA-256 fingerprints are added in Firebase Console, then try again.';
      case 'invalid-phone-number':
        return 'Invalid phone number. Include country code (e.g., +63...).';
      case 'too-many-requests':
        return 'Too many attempts. Please wait and try again later.';
      case 'invalid-verification-code':
        return 'Invalid code. Please check the SMS and try again.';
      case 'session-expired':
        return 'Code expired. Please resend a new code.';
      case 'credential-already-in-use':
        return 'This phone number is already linked to another account.';
      case 'provider-already-linked':
        return 'Phone verification is already linked to this account.';
      default:
        return 'Phone verification failed (${e.code}).';
    }
  }

  Future<void> _signOut() async {
    final bool shouldSignOut = await showConfirmSignOutDialog(context);
    if (!shouldSignOut) return;

    try {
      await FirebaseAuth.instance.signOut();
    } catch (_) {
      // Best-effort.
    }

    if (!mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil(
      LoginPage.routeName,
      (Route<dynamic> route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final User? user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return const LoginPage();
    }

    if (!_supported) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Verify phone'),
          actions: <Widget>[TextButton(onPressed: _signOut, child: const Text('Sign out'))],
        ),
        body: const SafeArea(
          child: Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Phone verification is not available on web in this build.',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      );
    }

    final ThemeData theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Verify phone'),
        actions: <Widget>[
          TextButton(
            onPressed: _signOut,
            child: const Text('Sign out'),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Card(
                elevation: 4,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Text(
                        'Phone verification required',
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'To continue, verify your phone number. We will send a one-time code (OTP).',
                        style: theme.textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 18),
                      TextField(
                        controller: _phoneController,
                        enabled: !_sending && !_verifying,
                        keyboardType: TextInputType.phone,
                        decoration: const InputDecoration(
                          labelText: 'Phone number',
                          hintText: '+63XXXXXXXXXX',
                          prefixIcon: Icon(Icons.phone_outlined),
                        ),
                        textInputAction: TextInputAction.next,
                        onSubmitted: (_) => _sendCode(),
                      ),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: _sending ||
                                _verifying ||
                                _resendCooldownSecondsRemaining > 0
                            ? null
                            : _sendCode,
                        child: _sending
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : Text(
                                _resendCooldownSecondsRemaining > 0
                                    ? 'Resend available in ${_resendCooldownSecondsRemaining}s'
                                    : (_codeSent ? 'Resend code' : 'Send code'),
                              ),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _codeController,
                        enabled: _codeSent && !_sending && !_verifying,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'OTP code',
                          prefixIcon: Icon(Icons.lock_outline),
                        ),
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _verifyCode(),
                      ),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed:
                            !_codeSent || _sending || _verifying ? null : _verifyCode,
                        child: _verifying
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Text('Verify and continue'),
                      ),
                      if (_error != null) ...<Widget>[
                        const SizedBox(height: 12),
                        Text(
                          _error!,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.error,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
