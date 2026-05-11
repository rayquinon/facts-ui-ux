import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'widgets/confirm_sign_out_dialog.dart';

class PrivacyConsentPage extends StatefulWidget {
  const PrivacyConsentPage({super.key, this.nextRoute});

  static const String routeName = '/privacy-consent';

  final String? nextRoute;

  @override
  State<PrivacyConsentPage> createState() => _PrivacyConsentPageState();
}

class _PrivacyConsentPageState extends State<PrivacyConsentPage> {
  bool _hasAgreed = false;
  bool _isSubmitting = false;

  Future<void> _handleAgree() async {
    if (!_hasAgreed || _isSubmitting) return;

    setState(() => _isSubmitting = true);
    final User? user = FirebaseAuth.instance.currentUser;

    try {
      if (user != null) {
        // Update Firestore to mark privacy consent as accepted
        await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .update({
              'privacyConsentAt': FieldValue.serverTimestamp(),
              'privacyConsentVersion': '1.0',
            });
      }

      if (!mounted) return;
      
      // Determine the next route based on verification status
      final String nextRoute = widget.nextRoute ?? '/';
      Navigator.of(context).pushReplacementNamed(nextRoute);
    } catch (error) {
      if (!mounted) return;
      setState(() => _isSubmitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to save consent: $error'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _handleSignOut() async {
    final bool shouldSignOut = await showConfirmSignOutDialog(context);
    if (!mounted) return;
    if (!shouldSignOut) return;

    try {
      await FirebaseAuth.instance.signOut();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to sign out. Please try again.'),
          ),
        );
      }
      return;
    }

    if (mounted) {
      Navigator.of(context)
          .pushNamedAndRemoveUntil('/login', (Route<dynamic> route) => false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Privacy Notice & Consent'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Sign out',
            onPressed: _isSubmitting ? null : _handleSignOut,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 800),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  'Data Privacy Notice',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: theme.colorScheme.outline),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'Privacy & Data Processing',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'This platform uses face recognition technology to facilitate attendance tracking. '
                        'Your facial biometric data (face embeddings) will be processed and stored securely. '
                        'This data is used exclusively for attendance verification and is protected in accordance with data protection regulations.',
                        style: theme.textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Your Consent',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'By checking the box below, you acknowledge that you have read and understand this privacy notice, and you consent to the processing of your facial biometric data for attendance purposes.',
                        style: theme.textTheme.bodySmall,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'You may withdraw your consent at any time by contacting your administrator.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontStyle: FontStyle.italic,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                Card(
                  child: CheckboxListTile(
                    title: Text(
                      'I agree to the Data Privacy Notice and consent to face embedding processing for attendance',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    value: _hasAgreed,
                    onChanged: _isSubmitting
                        ? null
                        : (bool? value) {
                            setState(() => _hasAgreed = value ?? false);
                          },
                  ),
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: _hasAgreed && !_isSubmitting ? _handleAgree : null,
                  icon: const Icon(Icons.check_circle_outline),
                  label: _isSubmitting
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                          ),
                        )
                      : const Text('Continue'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                  ),
                ),
                const SizedBox(height: 16),
                TextButton(
                  onPressed: _isSubmitting ? null : _handleSignOut,
                  child: const Text('Sign out instead'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

