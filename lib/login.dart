// ignore_for_file: use_build_context_synchronously

import 'dart:math' as math;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'signup_pickrole.dart';
import 'widgets/clay_surface.dart';
import 'services/user_role_service.dart';
import 'services/app_update_service.dart';
import 'services/app_update_types.dart';
import 'services/web_update_service.dart';
import 'verify_email_page.dart';

/// Standalone login page with simple validation and submit feedback.
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  static const String routeName = '/login';

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  bool _obscurePassword = true;
  bool _isSubmitting = false;
  String? _appVersionLabel;
  bool _autoUpdatePromptShown = false;

  static final RegExp _emailRegex = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  @override
  void initState() {
    super.initState();
    _loadAppVersionLabel();
    _scheduleAutoUpdatePrompt();
  }

  void _scheduleAutoUpdatePrompt() {
    // Only auto-prompt on Android. Web already has a reload prompt mechanism.
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || _autoUpdatePromptShown) return;
      _autoUpdatePromptShown = true;
      await _checkForUpdates(showUpToDateDialog: false);
    });
  }

  Future<void> _loadAppVersionLabel() async {
    try {
      final PackageInfo info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() {
        _appVersionLabel = '${info.version}+${info.buildNumber}';
      });
    } catch (_) {
      // Best-effort only.
    }
  }

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
      final User user = credential.user!;
      final IdTokenResult token = await user.getIdTokenResult(true);
      final bool isAdmin =
          token.claims != null &&
          (token.claims!['admin'] == true || token.claims!['admin'] == 'true');

      String welcomeMessage = 'Welcome back, ${user.email ?? email}';

      if (isAdmin) {
        welcomeMessage = 'Signed in as Admin';
      } else {
        final String? role = await UserRoleService.fetchRoleByUid(
          user.uid,
          attemptRepairIfMissing: true,
        );
        if (role == 'student') {
          welcomeMessage = 'Welcome back, student!';
        } else if (role == 'instructor') {
          welcomeMessage = 'Welcome back, instructor!';
        } else if (role == 'admin') {
          // Role-based admin access is bootstrapped into an admin custom claim
          // via the AuthGate. Allow login to proceed so the bootstrap view can run.
          welcomeMessage = 'Welcome back, admin!';
        } else {
          // Don't block sign-in. AuthGate may be able to repair the role or
          // show a clearer next step.
          welcomeMessage = 'Welcome back!';
        }
      }

      messenger.showSnackBar(
        SnackBar(
          content: Text(welcomeMessage),
          behavior: SnackBarBehavior.floating,
        ),
      );

      if (!mounted) return;

      if (!isAdmin && !user.emailVerified) {
        bool sent = false;
        FirebaseAuthException? sendError;
        try {
          await user.sendEmailVerification();
          sent = true;
        } on FirebaseAuthException catch (error) {
          sendError = error;
        }
        if (!mounted) return;
        if (sendError != null) {
          messenger.showSnackBar(
            SnackBar(
              content: Text(
                'Could not send verification email (${sendError.code}). You can retry from the verification screen.',
              ),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        if (sent) {
          messenger.showSnackBar(
            SnackBar(
              content: Text(
                'We sent a verification link to ${user.email ?? email}. Verify to continue.',
              ),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        Navigator.of(context).pushReplacementNamed(
          VerifyEmailPage.routeName,
          arguments: const VerifyEmailPageArgs(destinationRoute: '/'),
        );
        return;
      }

      // Always go through AuthGate so any new gates (phone verification, etc)
      // are applied consistently.
      Navigator.of(
        context,
      ).pushNamedAndRemoveUntil('/', (Route<dynamic> route) => false);
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

  Future<void> _handleForgotPassword() async {
    if (!mounted) return;

    final TextEditingController emailController = TextEditingController(
      text: _emailController.text.trim(),
    );

    final String? email = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('Reset password'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const Text(
                  'Enter your email address and we\'ll send you a password reset link.',
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: emailController,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) {
                    Navigator.of(
                      dialogContext,
                    ).pop(emailController.text.trim());
                  },
                  decoration: const InputDecoration(
                    labelText: 'Email',
                    prefixIcon: Icon(Icons.mail_outline),
                  ),
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(null),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(dialogContext).pop(emailController.text.trim());
              },
              child: const Text('Send link'),
            ),
          ],
        );
      },
    );

    // Avoid disposing the controller during the dialog route tear-down.
    Future<void>.microtask(emailController.dispose);

    final String trimmedEmail = (email ?? '').trim();
    if (trimmedEmail.isEmpty) return;
    if (!_emailRegex.hasMatch(trimmedEmail)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Enter a valid email address.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    if (!mounted) return;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Sending reset link...'),
        behavior: SnackBarBehavior.floating,
      ),
    );

    try {
      // Dynamic Links is required for handleCodeInApp flows, but is no longer
      // available in some Firebase Console versions/projects. Instead, use the
      // standard Firebase reset email which points to /__/auth/action.
      // We capture that link via Android App Links and complete reset in-app.
      await FirebaseAuth.instance.sendPasswordResetEmail(email: trimmedEmail);
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text('Password reset link sent to $trimmedEmail.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } on FirebaseAuthException catch (error) {
      if (!mounted) return;
      String message;
      switch (error.code) {
        case 'invalid-email':
          message = 'That email address looks invalid.';
          break;
        case 'user-not-found':
          // Avoid account enumeration; show generic message.
          message =
              'If an account exists for that email, a reset link will be sent.';
          break;
        case 'too-many-requests':
          message = 'Too many requests. Please try again later.';
          break;
        default:
          message = 'Could not send reset email (${error.code}). Try again.';
          break;
      }
      messenger.showSnackBar(
        SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
      );
    } catch (_) {
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Could not send reset email. Please try again.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _checkForUpdates({bool showUpToDateDialog = true}) async {
    if (kIsWeb) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Checking for updates...'),
          behavior: SnackBarBehavior.floating,
        ),
      );

      final WebUpdateCheck result = await WebUpdateService.instance
          .checkForUpdates();
        if (!mounted) return;

      if (!result.supported) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('This browser does not support update checks.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }

      if (result.error != null && result.error!.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Update check failed: ${result.error}'),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }

      if (result.updateAvailable == true) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Update available. Tap Reload on the prompt.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No update found right now.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    if (defaultTargetPlatform != TargetPlatform.android) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Updates are available on Android builds only.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    final AppUpdateInfo? update = await AppUpdateService.instance
        .checkForUpdate();
    if (!mounted) return;

    if (update == null) {
      if (showUpToDateDialog) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not check for updates right now.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    final String currentLabel =
        '${update.currentVersion}+${update.currentBuildNumber}';
    final String latestLabel = update.effectiveLatestLabel;

    if (!update.updateAvailable) {
      if (!showUpToDateDialog) return;
      await showDialog<void>(
        context: context,
        builder: (BuildContext dialogContext) {
          return AlertDialog(
            title: const Text('Up to date'),
            content: Text('You are on the latest version ($currentLabel).'),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('OK'),
              ),
            ],
          );
        },
      );
      return;
    }

    final bool? shouldUpdate = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('Update available'),
          content: Text(
            'A newer version is available.\n\n'
            'Current: $currentLabel\n'
            'Latest:  $latestLabel\n\n'
            'Download and install the update now?',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Update now'),
            ),
          ],
        );
      },
    );

    if (shouldUpdate != true) return;

    await _downloadAndInstallAndroidUpdate(update);
  }

  Future<void> _downloadAndInstallAndroidUpdate(AppUpdateInfo update) {
    if (!mounted) return Future<void>.value();

    final BuildContext rootContext = context;
    if (!rootContext.mounted) return Future<void>.value();

    int receivedBytes = 0;
    int totalBytes = 0;
    Object? updateError;
    bool dialogOpen = true;
    bool started = false;

    return showDialog<void>(
      context: rootContext,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return StatefulBuilder(
          builder: (BuildContext _, void Function(void Function()) setState) {
            if (!started) {
              started = true;
              Future<void>.microtask(() async {
                final NavigatorState navigator = Navigator.of(dialogContext);
                try {
                  await AppUpdateService.instance.downloadAndInstallUpdate(
                    update,
                    onProgress: (int received, int total) {
                      receivedBytes = received;
                      totalBytes = total;
                      if (dialogOpen) {
                        setState(() {});
                      }
                    },
                  );
                } catch (e) {
                  updateError = e;
                } finally {
                  if (navigator.canPop()) {
                    dialogOpen = false;
                    navigator.pop();
                  }
                }
              });
            }

            final double? progress = totalBytes > 0
                ? (receivedBytes / totalBytes).clamp(0.0, 1.0)
                : null;

            String label = 'Downloading update…';
            if (progress != null) {
              final int percent = (progress * 100).round();
              label = 'Downloading update… $percent%';
            }

            return AlertDialog(
              title: const Text('Updating…'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(label),
                  const SizedBox(height: 12),
                  LinearProgressIndicator(value: progress),
                  const SizedBox(height: 8),
                  Text(
                    'Android will ask you to confirm install.',
                    style: Theme.of(dialogContext).textTheme.bodySmall,
                  ),
                ],
              ),
            );
          },
        );
      },
    ).then((_) {
      if (!mounted) return;
      if (updateError == null) return;
      if (!rootContext.mounted) return;

      ScaffoldMessenger.of(rootContext).showSnackBar(
        SnackBar(
          content: Text(
            updateError is AppUpdateNeedsInstallPermission
                ? 'Enable "Install unknown apps" for FACTS, then tap Update again.'
                : 'Update failed: $updateError',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    });
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
    final Size screenSize = MediaQuery.sizeOf(context);
    final bool showLogo = !isDesktop;
    final bool isShortScreen = screenSize.height < 720;
    final double logoMaxHeight = isTablet
        ? (isShortScreen ? 120 : 150)
        : (isShortScreen ? 96 : 120);
    final double logoMaxWidth = math.min(
      isTablet ? 320 : 260,
      screenSize.width * (isTablet ? 0.45 : 0.60),
    );

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
              if (showLogo)
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: logoMaxHeight,
                    maxWidth: logoMaxWidth,
                  ),
                  child: Image.asset(
                    'assets/logo.png',
                    fit: BoxFit.contain,
                    filterQuality: FilterQuality.high,
                    errorBuilder:
                        (
                          BuildContext context,
                          Object error,
                          StackTrace? stackTrace,
                        ) {
                          return const SizedBox.shrink();
                        },
                  ),
                ),
              if (showLogo) SizedBox(height: isShortScreen ? 12 : 16),
              _buildHeading(theme, isTablet),
              SizedBox(height: isShortScreen ? 24 : 32),
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
                      onPressed: _handleForgotPassword,
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
                  if (kIsWeb || defaultTargetPlatform == TargetPlatform.android)
                    Align(
                      alignment: isTablet
                          ? Alignment.centerLeft
                          : Alignment.center,
                      child: TextButton.icon(
                        onPressed: _checkForUpdates,
                        icon: const Icon(Icons.system_update_alt, size: 18),
                        label: const Text(
                          'Check for updates',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          softWrap: false,
                        ),
                        style: TextButton.styleFrom(
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    ),
                  if (_appVersionLabel != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        'Version: ${_appVersionLabel!}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.6,
                          ),
                        ),
                        textAlign: isTablet ? TextAlign.left : TextAlign.center,
                      ),
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
    return ClaySurface(
      borderRadius: BorderRadius.circular(28),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Opacity(
            opacity: 0.9,
            child: Image.asset(
              'assets/logo.png',
              fit: BoxFit.contain,
              errorBuilder:
                  (BuildContext context, Object error, StackTrace? stackTrace) {
                    return const SizedBox.shrink();
                  },
            ),
          ),
        ),
      ),
    );
  }
}
