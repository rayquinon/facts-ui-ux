import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'instructor_page.dart';
import 'login.dart';
import 'services/user_role_service.dart';
import 'student_page.dart';

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
  bool _isSending = false;
  bool _isRefreshing = false;
  DateTime? _lastSentAt;
  bool _autoSent = false;

  bool get _canResend {
    final DateTime? lastSentAt = _lastSentAt;
    if (lastSentAt == null) return true;
    return DateTime.now().difference(lastSentAt) >= const Duration(seconds: 30);
  }

  Future<void> _sendVerificationEmail() async {
    final User? user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    if (_isSending || !_canResend) return;

    setState(() => _isSending = true);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);

    try {
      await user.sendEmailVerification();
      setState(() => _lastSentAt = DateTime.now());
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Verification email sent. Please check your inbox.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } on FirebaseAuthException catch (error) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('Failed to send email (${error.code}).'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (_) {
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
    final String? explicitDestination = widget.destinationRoute;
    if (explicitDestination != null && explicitDestination.isNotEmpty) {
      Navigator.of(context).pushNamedAndRemoveUntil(
        explicitDestination,
        (Route<dynamic> route) => false,
      );
      return;
    }

    // Deep-link / direct navigation case: infer destination from profile role.
    final String uid = user?.uid ?? FirebaseAuth.instance.currentUser?.uid ?? '';
    if (uid.isEmpty) return;

    try {
      final String? role = await UserRoleService.fetchRoleByUid(uid);
      if (!mounted) return;
      final String? inferred = switch (role) {
        'student' => StudentPage.routeName,
        'instructor' => InstructorPage.routeName,
        _ => null,
      };
      if (inferred == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Verified, but your profile role could not be loaded. Please sign out and sign in again.',
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }
      Navigator.of(context).pushNamedAndRemoveUntil(
        inferred,
        (Route<dynamic> route) => false,
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Verified, but failed to load your profile. Please sign out and sign in again.',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
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
                        _canResend
                            ? (_isSending
                                  ? 'Sending…'
                                  : 'Resend verification email')
                            : 'Resend available in a moment',
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
