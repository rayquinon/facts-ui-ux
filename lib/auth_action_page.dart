import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'login.dart';
import 'reset_password_page.dart';

class AuthActionPage extends StatefulWidget {
  const AuthActionPage({super.key, required this.uri});

  final Uri uri;

  @override
  State<AuthActionPage> createState() => _AuthActionPageState();
}

enum _AuthActionKind { verifyEmail, resetPassword, unsupported, invalid }

class _AuthActionOutcome {
  const _AuthActionOutcome({
    required this.kind,
    this.oobCode,
    this.message,
    this.errorCode,
  });

  final _AuthActionKind kind;
  final String? oobCode;
  final String? message;
  final String? errorCode;
}

class _AuthActionPageState extends State<AuthActionPage> {
  late final Future<_AuthActionOutcome> _outcome = _handle();

  String _query(String key) => (widget.uri.queryParameters[key] ?? '').trim();

  Future<_AuthActionOutcome> _handle() async {
    final String mode = _query('mode');
    final String code = (_query('oobCode').isNotEmpty)
        ? _query('oobCode')
        : _query('oob');

    if (mode.isEmpty) {
      return const _AuthActionOutcome(
        kind: _AuthActionKind.invalid,
        message: 'Missing action mode.',
      );
    }

    if (mode == 'resetPassword') {
      if (code.isEmpty) {
        return const _AuthActionOutcome(
          kind: _AuthActionKind.invalid,
          message: 'Missing password reset code.',
        );
      }
      return _AuthActionOutcome(
        kind: _AuthActionKind.resetPassword,
        oobCode: code,
      );
    }

    if (mode != 'verifyEmail') {
      return _AuthActionOutcome(
        kind: _AuthActionKind.unsupported,
        message: 'Unsupported action: $mode',
      );
    }

    if (code.isEmpty) {
      return const _AuthActionOutcome(
        kind: _AuthActionKind.invalid,
        message: 'Missing email verification code.',
      );
    }

    try {
      await FirebaseAuth.instance.applyActionCode(code);
      final User? user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        await user.reload();
      }
      return const _AuthActionOutcome(
        kind: _AuthActionKind.verifyEmail,
        message: 'Email verified successfully.',
      );
    } on FirebaseAuthException catch (error) {
      return _AuthActionOutcome(
        kind: _AuthActionKind.invalid,
        message: 'Verification failed (${error.code}).',
        errorCode: error.code,
      );
    } catch (_) {
      return const _AuthActionOutcome(
        kind: _AuthActionKind.invalid,
        message: 'Verification failed. Please try again.',
      );
    }
  }

  void _goHome() {
    Navigator.of(context).pushNamedAndRemoveUntil('/', (_) => false);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_AuthActionOutcome>(
      future: _outcome,
      builder: (BuildContext context, AsyncSnapshot<_AuthActionOutcome> snap) {
        if (!snap.hasData) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        final _AuthActionOutcome out = snap.data!;

        if (out.kind == _AuthActionKind.resetPassword) {
          return ResetPasswordPage(oobCode: out.oobCode ?? '');
        }

        final ThemeData theme = Theme.of(context);
        final String title = out.kind == _AuthActionKind.verifyEmail
            ? 'Email verified'
            : 'Action link';

        return Scaffold(
          appBar: AppBar(title: Text(title)),
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
                          out.message ?? 'Done.',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 16),
                        FilledButton(
                          onPressed: _goHome,
                          child: const Text('Continue'),
                        ),
                        if (FirebaseAuth.instance.currentUser == null)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: OutlinedButton(
                              onPressed: () {
                                Navigator.of(context).pushNamedAndRemoveUntil(
                                  LoginPage.routeName,
                                  (_) => false,
                                );
                              },
                              child: const Text('Go to login'),
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
      },
    );
  }
}
