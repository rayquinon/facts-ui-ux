import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'login.dart';

class ResetPasswordPageArgs {
  const ResetPasswordPageArgs({required this.oobCode});

  final String oobCode;
}

class ResetPasswordPage extends StatefulWidget {
  const ResetPasswordPage({super.key, required this.oobCode});

  static const String routeName = '/reset-password';

  final String oobCode;

  @override
  State<ResetPasswordPage> createState() => _ResetPasswordPageState();
}

class _ResetPasswordPageState extends State<ResetPasswordPage> {
  final TextEditingController _otpController = TextEditingController();
  final TextEditingController _newPasswordController = TextEditingController();
  final TextEditingController _confirmPasswordController = TextEditingController();

  bool _loading = true;
  bool _sendingOtp = false;
  bool _verifyingOtp = false;
  bool _otpSent = false;
  bool _otpVerified = false;
  bool _saving = false;
  bool _obscurePassword = true;

  String? _email;
  String? _phoneNumber;
  String? _maskedPhone;

  String? _verificationId;
  int? _resendToken;
  String? _error;

  bool get _supported => !kIsWeb;

  @override
  void dispose() {
    _otpController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _loadResetInfo();
  }

  Future<void> _loadResetInfo() async {
    if (!_supported) {
      setState(() {
        _loading = false;
        _error = 'Password reset is only supported in the Android app.';
      });
      return;
    }

    final String code = widget.oobCode.trim();
    if (code.isEmpty) {
      setState(() {
        _loading = false;
        _error = 'Reset link is missing a code. Please request a new reset email.';
      });
      return;
    }

    try {
      final HttpsCallable callable = FirebaseFunctions.instanceFor(
        region: 'us-central1',
      ).httpsCallable('getPasswordResetPhone');

      final HttpsCallableResult<dynamic> res = await callable.call(
        <String, Object?>{'oobCode': code},
      );

      final Map<String, dynamic> data =
          (res.data as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};

      final String email = (data['email'] as String?)?.trim() ?? '';
      final String phone = (data['phoneNumber'] as String?)?.trim() ?? '';
      final String masked = (data['maskedPhone'] as String?)?.trim() ?? '';

      if (email.isEmpty || phone.isEmpty) {
        throw StateError('Reset data was incomplete.');
      }

      if (!mounted) return;
      setState(() {
        _email = email;
        _phoneNumber = phone;
        _maskedPhone = masked.isEmpty ? phone : masked;
        _loading = false;
      });
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _mapFunctionsError(e);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not validate the reset link. Please request a new one.';
      });
    }
  }

  String _mapFunctionsError(FirebaseFunctionsException e) {
    final String code = (e.code).toLowerCase();
    if (code == 'invalid-argument') {
      return 'This reset link is invalid or expired. Please request a new reset email.';
    }
    if (code == 'failed-precondition') {
      return 'No phone number is linked to this account. Please contact support.';
    }
    return 'Could not validate the reset link. Please try again.';
  }

  Future<void> _sendOtp({bool forceResend = false}) async {
    if (!_supported) return;
    if (_sendingOtp || _verifyingOtp || _saving) return;

    final String phone = (_phoneNumber ?? '').trim();
    if (phone.isEmpty) return;

    setState(() {
      _sendingOtp = true;
      _error = null;
    });

    final Completer<void> completer = Completer<void>();

    try {
      await FirebaseAuth.instance.verifyPhoneNumber(
        phoneNumber: phone,
        timeout: const Duration(seconds: 60),
        forceResendingToken: forceResend ? _resendToken : null,
        verificationCompleted: (PhoneAuthCredential credential) async {
          try {
            await FirebaseAuth.instance.signInWithCredential(credential);
            try {
              await FirebaseAuth.instance.signOut();
            } catch (_) {
              // Best-effort.
            }
            if (!mounted) return;
            setState(() {
              _otpSent = true;
              _otpVerified = true;
              _error = null;
            });
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
          if (!completer.isCompleted) completer.complete();
        },
        codeSent: (String verificationId, int? resendToken) {
          if (mounted) {
            setState(() {
              _verificationId = verificationId;
              _resendToken = resendToken;
              _otpSent = true;
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
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Failed to send OTP. Please try again.');
      }
      if (!completer.isCompleted) completer.complete();
    } finally {
      await completer.future;
      if (mounted) setState(() => _sendingOtp = false);
    }
  }

  Future<void> _verifyOtp() async {
    if (!_supported) return;
    if (_verifyingOtp || _sendingOtp || _saving) return;
    if (_otpVerified) return;

    final String verificationId = (_verificationId ?? '').trim();
    final String smsCode = _otpController.text.trim();
    if (verificationId.isEmpty || smsCode.isEmpty) {
      setState(() => _error = 'Enter the 6-digit code we sent to your phone.');
      return;
    }

    setState(() {
      _verifyingOtp = true;
      _error = null;
    });

    try {
      final PhoneAuthCredential credential = PhoneAuthProvider.credential(
        verificationId: verificationId,
        smsCode: smsCode,
      );
      await FirebaseAuth.instance.signInWithCredential(credential);
      try {
        await FirebaseAuth.instance.signOut();
      } catch (_) {
        // Best-effort.
      }
      if (!mounted) return;
      setState(() {
        _otpVerified = true;
        _error = null;
      });
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      setState(() => _error = _mapAuthError(e));
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'OTP verification failed. Please try again.');
    } finally {
      if (mounted) setState(() => _verifyingOtp = false);
    }
  }

  String _mapAuthError(FirebaseAuthException e) {
    switch (e.code) {
      case 'invalid-phone-number':
        return 'Invalid phone number on file. Please contact support.';
      case 'too-many-requests':
        return 'Too many attempts. Please wait and try again later.';
      case 'invalid-verification-code':
        return 'Invalid code. Please check the SMS and try again.';
      case 'session-expired':
        return 'Code expired. Please resend a new code.';
      default:
        return 'Phone verification failed (${e.code}).';
    }
  }

  Future<void> _confirmNewPassword() async {
    if (!_supported) return;
    if (_saving || !_otpVerified) return;

    final String pass = _newPasswordController.text;
    final String confirm = _confirmPasswordController.text;
    if (pass.trim().isEmpty || confirm.trim().isEmpty) {
      setState(() => _error = 'Enter your new password twice.');
      return;
    }
    if (pass != confirm) {
      setState(() => _error = 'Passwords do not match.');
      return;
    }
    if (pass.length < 6) {
      setState(() => _error = 'Password must be at least 6 characters.');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      await FirebaseAuth.instance.confirmPasswordReset(
        code: widget.oobCode.trim(),
        newPassword: pass,
      );
      try {
        await FirebaseAuth.instance.signOut();
      } catch (_) {
        // Best-effort.
      }

      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (BuildContext dialogContext) {
          return AlertDialog(
            title: const Text('Password updated'),
            content: const Text('Your password was changed successfully. Please log in again.'),
            actions: <Widget>[
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('OK'),
              ),
            ],
          );
        },
      );
      if (!mounted) return;
      Navigator.of(context).pushNamedAndRemoveUntil(
        LoginPage.routeName,
        (Route<dynamic> route) => false,
      );
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Reset failed (${e.code}). Please request a new reset email.');
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Reset failed. Please request a new reset email.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    if (!_supported) {
      return Scaffold(
        appBar: AppBar(title: const Text('Reset password')),
        body: const SafeArea(
          child: Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Password reset is not available on web in this build.',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Reset password')),
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
                        'Reset your password',
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (_loading) ...<Widget>[
                        const Center(child: CircularProgressIndicator()),
                      ] else ...<Widget>[
                        if (_email != null && _email!.isNotEmpty) ...<Widget>[
                          Text(
                            'Account: ${_email!}',
                            style: theme.textTheme.bodyMedium,
                          ),
                          const SizedBox(height: 8),
                        ],
                        Text(
                          'We will send a one-time code to ${_maskedPhone ?? 'your phone'} to confirm it\'s you.',
                          style: theme.textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 16),
                        FilledButton(
                          onPressed: _sendingOtp || _verifyingOtp || _saving
                              ? null
                              : () => _sendOtp(forceResend: _otpSent),
                          child: _sendingOtp
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : Text(_otpSent ? 'Resend OTP' : 'Send OTP'),
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          controller: _otpController,
                          enabled: _otpSent && !_otpVerified && !_sendingOtp && !_verifyingOtp,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'OTP code',
                            prefixIcon: Icon(Icons.lock_outline),
                          ),
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) => _verifyOtp(),
                        ),
                        const SizedBox(height: 12),
                        FilledButton(
                          onPressed: !_otpSent || _otpVerified || _sendingOtp || _verifyingOtp
                              ? null
                              : _verifyOtp,
                          child: _verifyingOtp
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : Text(_otpVerified ? 'Verified' : 'Verify OTP'),
                        ),
                        const SizedBox(height: 16),
                        if (_otpVerified) ...<Widget>[
                          TextField(
                            controller: _newPasswordController,
                            enabled: !_saving,
                            obscureText: _obscurePassword,
                            decoration: InputDecoration(
                              labelText: 'New password',
                              prefixIcon: const Icon(Icons.password_outlined),
                              suffixIcon: IconButton(
                                onPressed: () => setState(() {
                                  _obscurePassword = !_obscurePassword;
                                }),
                                icon: Icon(
                                  _obscurePassword
                                      ? Icons.visibility_outlined
                                      : Icons.visibility_off_outlined,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _confirmPasswordController,
                            enabled: !_saving,
                            obscureText: _obscurePassword,
                            decoration: const InputDecoration(
                              labelText: 'Confirm password',
                              prefixIcon: Icon(Icons.password_outlined),
                            ),
                          ),
                          const SizedBox(height: 12),
                          FilledButton(
                            onPressed: _saving ? null : _confirmNewPassword,
                            child: _saving
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : const Text('Set new password'),
                          ),
                        ],
                      ],
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
