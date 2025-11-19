import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'admin_page.dart';
import 'instructor_page.dart';
import 'signup_pickrole.dart';
import 'student_page.dart';
import 'constants/auth_constants.dart';
import 'services/user_role_service.dart';

/// Standalone login page with simple validation and submit feedback.
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  static const String routeName = '/login';

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  static const String _factsDescription =
      'The F.A.C.T.S. project (Facial Attendance for Compliance and Tracking of '
      'Students) is an innovative attendance information system designed to replace '
      'time-consuming, error-prone manual processes. The core application is an '
      'integrated mobile app for instructors to use facial recognition to scan '
      'students and log attendance, absences, and lateness in real-time, ensuring '
      'superior accuracy and eliminating proxy attendance. This is complemented by '
      'a web platform that enables the creation of reports in the official school '
      'format for compliance and provides faculty and administrators with actionable '
      'analytics to track attendance patterns, which is critical for student '
      'performance and retention. The system features real-time data synchronization, '
      'role-based access, and a key "Online Synch capability" for reliable attendance '
      'taking even when the internet is initially unavailable.';
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  bool _obscurePassword = true;
  bool _isSubmitting = false;

  void _openSignUpPage() {
    Navigator.of(context).pushNamed(SignupPickRolePage.routeName);
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _handleSubmit() async {
    final bool isValid = _formKey.currentState?.validate() ?? false;
    if (!isValid || _isSubmitting) return;

    FocusScope.of(context).unfocus();
    setState(() => _isSubmitting = true);

    final String email = _emailController.text.trim();
    final String password = _passwordController.text.trim();
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);

    try {
      final UserCredential credential = await FirebaseAuth.instance
          .signInWithEmailAndPassword(email: email, password: password);
      final User? user = credential.user;
      final String normalizedAdminEmail = kAdminEmail.toLowerCase();
      final bool isAdmin =
          (user?.email ?? '').toLowerCase() == normalizedAdminEmail;

      late final String destinationRoute;
      String welcomeMessage = 'Welcome back, ${user?.email ?? email}';

      if (isAdmin) {
        destinationRoute = AdminPage.routeName;
        welcomeMessage = 'Signed in as Admin';
      } else {
        final String? role = await UserRoleService.fetchRoleByUid(user?.uid);
        if (role == 'student') {
          destinationRoute = StudentPage.routeName;
          welcomeMessage = 'Welcome back, student!';
        } else if (role == 'instructor') {
          destinationRoute = InstructorPage.routeName;
          welcomeMessage = 'Welcome back, instructor!';
        } else {
          messenger.showSnackBar(
            const SnackBar(
              content: Text(
                'Your profile is missing a role assignment. Contact support.',
              ),
              behavior: SnackBarBehavior.floating,
            ),
          );
          return;
        }
      }

      messenger.showSnackBar(
        SnackBar(
          content: Text(welcomeMessage),
          behavior: SnackBarBehavior.floating,
        ),
      );

      if (mounted) {
        Navigator.of(context).pushReplacementNamed(destinationRoute);
      }
    } on FirebaseAuthException catch (error) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(_mapAuthError(error)),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Something went wrong. Please try again.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  String _mapAuthError(FirebaseAuthException error) {
    switch (error.code) {
      case 'invalid-credential':
      case 'wrong-password':
        return 'Incorrect email or password.';
      case 'user-not-found':
        return 'No account found for that email.';
      case 'user-disabled':
        return 'This account has been disabled.';
      case 'too-many-requests':
        return 'Too many attempts. Please try again later.';
      default:
        return 'Sign-in failed (${error.code}). Please try again.';
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final bool isDesktop = constraints.maxWidth >= 1024;
            final bool isTablet = constraints.maxWidth >= 600;
            final double horizontalPadding = isDesktop
                ? 72
                : (isTablet ? 48 : 24);
            final double verticalPadding = isDesktop ? 56 : 32;

            final Widget formSection = _buildFormSection(
              theme: theme,
              isTablet: isTablet,
              isDesktop: isDesktop,
              horizontalPadding: horizontalPadding,
              verticalPadding: verticalPadding,
            );

            if (!isDesktop) return formSection;

            return Row(
              children: <Widget>[
                Expanded(
                  flex: 5,
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: horizontalPadding,
                      vertical: verticalPadding,
                    ),
                    child: _buildPromoPanel(theme),
                  ),
                ),
                Expanded(flex: 4, child: formSection),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildFormSection({
    required ThemeData theme,
    required bool isTablet,
    required bool isDesktop,
    required double horizontalPadding,
    required double verticalPadding,
  }) {
    final EdgeInsets contentPadding = EdgeInsets.symmetric(
      horizontal: isDesktop ? horizontalPadding / 2 : horizontalPadding,
      vertical: verticalPadding,
    );

    return Center(
      child: SingleChildScrollView(
        padding: contentPadding,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: isDesktop ? 520 : 440),
          child: Column(
            crossAxisAlignment: isTablet
                ? CrossAxisAlignment.start
                : CrossAxisAlignment.center,
            children: <Widget>[
              _buildHeading(theme, isTablet),
              const SizedBox(height: 32),
              _buildFormCard(theme, isTablet: isTablet),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeading(ThemeData theme, bool isTablet) {
    final TextAlign align = isTablet ? TextAlign.start : TextAlign.center;
    return Column(
      crossAxisAlignment: isTablet
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.center,
      children: <Widget>[
        Text(
          'Welcome back',
          textAlign: align,
          style:
              (isTablet
                      ? theme.textTheme.headlineLarge
                      : theme.textTheme.headlineMedium)
                  ?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Text(
          'Enter your credentials to continue.',
          textAlign: align,
          style: theme.textTheme.bodyMedium,
        ),
      ],
    );
  }

  Widget _buildFormCard(ThemeData theme, {required bool isTablet}) {
    final double cardPadding = isTablet ? 32 : 24;
    final double fieldSpacing = isTablet ? 24 : 16;

    return FocusTraversalGroup(
      child: AutofillGroup(
        child: Card(
          elevation: isTablet ? 6 : 4,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          child: Padding(
            padding: EdgeInsets.all(cardPadding),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  TextFormField(
                    controller: _emailController,
                    autofillHints: const <String>[AutofillHints.username],
                    decoration: const InputDecoration(
                      labelText: 'Email',
                      prefixIcon: Icon(Icons.mail_outline),
                    ),
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.next,
                    validator: (String? value) {
                      final String email = value?.trim() ?? '';
                      if (email.isEmpty) return 'Please enter your email';
                      final RegExp emailRegex = RegExp(
                        r'^[^@\s]+@[^@\s]+\.[^@\s]+$',
                      );
                      if (!emailRegex.hasMatch(email)) {
                        return 'Enter a valid email address';
                      }
                      return null;
                    },
                  ),
                  SizedBox(height: fieldSpacing),
                  TextFormField(
                    controller: _passwordController,
                    autofillHints: const <String>[AutofillHints.password],
                    decoration: InputDecoration(
                      labelText: 'Password',
                      prefixIcon: const Icon(Icons.lock_outline),
                      suffixIcon: IconButton(
                        onPressed: () => setState(
                          () => _obscurePassword = !_obscurePassword,
                        ),
                        icon: Icon(
                          _obscurePassword
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                      ),
                    ),
                    obscureText: _obscurePassword,
                    textInputAction: TextInputAction.done,
                    validator: (String? value) {
                      if ((value ?? '').isEmpty) {
                        return 'Please enter your password';
                      }
                      if ((value ?? '').length < 6) {
                        return 'Password must be at least 6 characters';
                      }
                      return null;
                    },
                    onFieldSubmitted: (_) => _handleSubmit(),
                  ),
                  SizedBox(height: fieldSpacing + 8),
                  FilledButton(
                    onPressed: _isSubmitting ? null : _handleSubmit,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(52),
                    ),
                    child: _isSubmitting
                        ? const SizedBox(
                            height: 22,
                            width: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                Colors.white,
                              ),
                            ),
                          )
                        : const Text('Sign in'),
                  ),
                  const SizedBox(height: 16),
                  Align(
                    alignment: isTablet
                        ? Alignment.centerLeft
                        : Alignment.center,
                    child: TextButton(
                      onPressed: () {},
                      child: const Text('Forgot your password?'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      Text(
                        'New to F.A.C.T.S.?',
                        style: theme.textTheme.bodyMedium,
                      ),
                      TextButton(
                        onPressed: _openSignUpPage,
                        child: const Text('Sign up'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPromoPanel(ThemeData theme) {
    final Color onPrimary = theme.colorScheme.onPrimary;
    final TextStyle? bodyStyle = theme.textTheme.bodyLarge?.copyWith(
      color: onPrimary.withValues(alpha: 0.95),
      height: 1.45,
    );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double minHeight = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : 0;
        final bool showThumb =
            constraints.maxHeight.isFinite && constraints.maxHeight < 640;

        return ClipRRect(
          borderRadius: BorderRadius.circular(28),
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: <Color>[
                  theme.colorScheme.primary,
                  theme.colorScheme.secondary,
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: Scrollbar(
              thumbVisibility: showThumb,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(40),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: minHeight),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      _buildLogoPlaceholder(onPrimary),
                      const SizedBox(height: 24),
                      Text(
                        'F.A.C.T.S.',
                        style: theme.textTheme.headlineMedium?.copyWith(
                          color: onPrimary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Facial Attendance for Compliance and Tracking of Students',
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: onPrimary.withValues(alpha: 0.9),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(_factsDescription, style: bodyStyle),
                      const SizedBox(height: 28),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: <Widget>[
                          _buildPlatformChip('Windows', onPrimary),
                          _buildPlatformChip('macOS', onPrimary),
                          _buildPlatformChip('iOS', onPrimary),
                          _buildPlatformChip('Android', onPrimary),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildPlatformChip(String label, Color textColor) {
    return Chip(
      backgroundColor: Colors.white.withValues(alpha: 0.15),
      label: Text(label, style: TextStyle(color: textColor)),
    );
  }

  Widget _buildLogoPlaceholder(Color accentColor) {
    return Container(
      width: 96,
      height: 96,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: accentColor.withValues(alpha: 0.08),
        border: Border.all(color: accentColor.withValues(alpha: 0.4), width: 2),
      ),
      alignment: Alignment.center,
      child: Icon(Icons.photo_library_outlined, color: accentColor, size: 40),
    );
  }
}
