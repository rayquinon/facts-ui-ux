import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'login.dart';
import 'widgets/confirm_sign_out_dialog.dart';

class VerifyEmailPageArgs {
  const VerifyEmailPageArgs({required this.destinationRoute});

  final String destinationRoute;
}

class VerifyEmailPage extends StatefulWidget {
  const VerifyEmailPage({super.key, this.destinationRoute});

  static const String routeName = '/verify-email';

  final String? destinationRoute;

  @override
  State<VerifyEmailPage> createState() => _VerifyEmailPageState();
}

class _VerifyEmailPageState extends State<VerifyEmailPage> {
  static const Duration _resendCooldown = Duration(minutes: 1);

  bool _isSending = false;
  bool _isRefreshing = false;
  bool _autoSent = false;

  DateTime? _resendCooldownEndsAt;
  Timer? _resendCooldownTimer;

  int get _resendCooldownSecondsRemaining {
    final DateTime? until = _resendCooldownEndsAt;
    if (until == null) return 0;
    final int seconds = until.difference(DateTime.now()).inSeconds;
    return seconds > 0 ? seconds : 0;
  }

  bool get _canResend => _resendCooldownSecondsRemaining <= 0;

  void _startResendCooldown() {
    _resendCooldownEndsAt = DateTime.now().add(_resendCooldown);
    _resendCooldownTimer?.cancel();
    _resendCooldownTimer = Timer.periodic(const Duration(seconds: 1), (
      Timer t,
    ) {
      if (!mounted) {
        t.cancel();
        return;
      }
      if (_resendCooldownSecondsRemaining <= 0) {
        setState(() {});
        _clearResendCooldown();
        return;
      }
      setState(() {});
    });
    setState(() {});
  }

  void _clearResendCooldown() {
    _resendCooldownEndsAt = null;
    _resendCooldownTimer?.cancel();
    _resendCooldownTimer = null;
  }

  Future<void> _sendVerificationEmail() async {
    final User? user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    if (_isSending) return;

    final int remaining = _resendCooldownSecondsRemaining;
    if (remaining > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Please wait ${remaining}s before resending the email.',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    setState(() => _isSending = true);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);

    _startResendCooldown();

    try {
      await user.sendEmailVerification();
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Verification email sent. Please check your inbox.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } on FirebaseAuthException catch (error) {
      _clearResendCooldown();
      messenger.showSnackBar(
        SnackBar(
          content: Text('Failed to send email (${error.code}).'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (_) {
      _clearResendCooldown();
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Failed to send verification email.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  @override
  void dispose() {
    _resendCooldownTimer?.cancel();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    // If the user lands here via AuthGate (app restart) there may not have
    // been an earlier send attempt. Auto-send once on entry.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _autoSent) return;
      _autoSent = true;
      _sendVerificationEmail();
    });
  }

  Future<void> _refreshStatus() async {
    final User? user = FirebaseAuth.instance.currentUser;
    if (user == null || _isRefreshing) return;

    setState(() => _isRefreshing = true);
    try {
      await user.reload();
      final User? refreshed = FirebaseAuth.instance.currentUser;
      final bool verified = refreshed?.emailVerified ?? false;
      if (!mounted) return;

      if (verified) {
        await _navigateAfterVerified(refreshed);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Not verified yet. Please check your email link.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Unable to refresh verification status.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _isRefreshing = false);
    }
  }

  Future<void> _navigateAfterVerified(User? user) async {
    // Update Firestore to mark email as verified.
    if (user != null) {
      try {
        await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .update({'emailVerificationStatus': 'verified'});
      } catch (_) {
        // Continue even if update fails; user has verified in Auth.
      }
    }
    // Always go through AuthGate so role-based gates (like phone verification)
    // are applied consistently.
    if (!mounted) return;
    Navigator.of(
      context,
    ).pushNamedAndRemoveUntil('/', (Route<dynamic> route) => false);
    return;
  }

  @override
  Widget build(BuildContext context) {
    final User? user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return const LoginPage();
    }

    final ThemeData theme = Theme.of(context);
    final String email = user.email ?? 'your email';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Verify your email'),
        actions: <Widget>[
          TextButton(
            onPressed: () async {
              final bool shouldSignOut = await showConfirmSignOutDialog(
                context,
              );
              if (!shouldSignOut) return;

              await FirebaseAuth.instance.signOut();
            },
            child: const Text('Sign out'),
          ),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
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
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Text(
                      'Check your inbox',
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'We sent a verification link to:\n$email\n\nOpen the email and click the link to verify your account.',
                      style: theme.textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: _isRefreshing ? null : _refreshStatus,
                      child: _isRefreshing
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('I have verified (Refresh)'),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton(
                      onPressed: _isSending || !_canResend
                          ? null
                          : _sendVerificationEmail,
                      child: Text(
                        _isSending
                            ? 'Sending…'
                            : (_canResend
                                  ? 'Resend verification email'
                                  : 'Resend available in ${_resendCooldownSecondsRemaining}s'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
