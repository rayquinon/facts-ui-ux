import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'admin_page.dart';
import 'face_enrollment_page.dart';
import 'firebase_options.dart';
import 'instructor_page.dart';
import 'login.dart';
import 'signup_pickrole.dart';
import 'student_page.dart';
import 'attendance_session_page.dart';
import 'services/crash_reporter.dart';
import 'services/user_role_service.dart';
import 'services/app_update_service.dart';
import 'services/app_update_types.dart';
import 'reports/generate_report_page.dart';
import 'reports/instructor_sessions_report_page.dart';
import 'verify_email_page.dart';
import 'widgets/confirm_sign_out_dialog.dart';
import 'widgets/android_only_feature_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Best-effort crash capture (especially for framework red-screen assertions).
  await CrashReporter.init();
  CrashReporter.installGlobalHandlers();

  if (kIsWeb) {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } else {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        // Uses native config (google-services.json / GoogleService-Info.plist).
        // Passing options here can cause a duplicate-app crash on some builds.
        await Firebase.initializeApp();
      case TargetPlatform.windows:
      case TargetPlatform.linux:
      case TargetPlatform.fuchsia:
        await Firebase.initializeApp(
          options: DefaultFirebaseOptions.currentPlatform,
        );
    }
  }

  runApp(const MyApp());
}

class FactsApp extends StatelessWidget {
  const FactsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Facts',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.light,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        visualDensity: VisualDensity.adaptivePlatformDensity,
        useMaterial3: true,
        pageTransitionsTheme: const PageTransitionsTheme(
          builders: <TargetPlatform, PageTransitionsBuilder>{
            TargetPlatform.android: FadeUpwardsPageTransitionsBuilder(),
            TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
            TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
            TargetPlatform.windows: FadeUpwardsPageTransitionsBuilder(),
            TargetPlatform.linux: FadeUpwardsPageTransitionsBuilder(),
            TargetPlatform.fuchsia: FadeUpwardsPageTransitionsBuilder(),
          },
        ),
      ),
      scrollBehavior: const MaterialScrollBehavior().copyWith(
        dragDevices: <PointerDeviceKind>{
          PointerDeviceKind.touch,
          PointerDeviceKind.mouse,
          PointerDeviceKind.trackpad,
          PointerDeviceKind.stylus,
        },
      ),
      home: const AuthGate(),
      routes: <String, WidgetBuilder>{
        LoginPage.routeName: (BuildContext context) => const LoginPage(),
        SignupPickRolePage.routeName: (BuildContext context) =>
            const SignupPickRolePage(),
        VerifyEmailPage.routeName: (BuildContext context) {
          final ModalRoute<dynamic>? route = ModalRoute.of(context);
          final VerifyEmailPageArgs? args =
              route?.settings.arguments as VerifyEmailPageArgs?;
          return VerifyEmailPage(destinationRoute: args?.destinationRoute);
        },
        AdminPage.routeName: (BuildContext context) => const AdminPage(),
        StudentPage.routeName: (BuildContext context) => const StudentPage(),
        InstructorPage.routeName: (BuildContext context) =>
            const InstructorPage(),
        FaceEnrollmentPage.routeName: (BuildContext context) {
          if (!isAndroidFaceScanningSupported()) {
            return const AndroidOnlyFeaturePage(featureName: 'Face Enrollment');
          }
          return const FaceEnrollmentPage();
        },
        GenerateReportPage.routeName: (BuildContext context) =>
            const GenerateReportPage(),
        InstructorSessionsReportPage.routeName: (BuildContext context) =>
            const InstructorSessionsReportPage(),
        AttendanceSessionPage.routeName: (BuildContext context) {
          final ModalRoute<dynamic>? route = ModalRoute.of(context);
          final AttendanceSessionConfig? config =
              route?.settings.arguments as AttendanceSessionConfig?;
          if (config == null) {
            return const UnknownRouteScreen(
              unknownRouteName: AttendanceSessionPage.routeName,
            );
          }

          if (!isAndroidFaceScanningSupported()) {
            return const AndroidOnlyFeaturePage(
              featureName: 'Attendance Face Scanning',
            );
          }
          return AttendanceSessionPage(config: config);
        },
      },
      onUnknownRoute: (RouteSettings settings) => MaterialPageRoute<void>(
        builder: (BuildContext context) =>
            UnknownRouteScreen(unknownRouteName: settings.name ?? 'unknown'),
      ),
    );
  }
}

/// Adapter class retained for the default Flutter test harness.
class MyApp extends FactsApp {
  const MyApp({super.key});
}

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  int _authRefreshKey = 0;
  bool _updateCheckedThisLaunch = false;

  void _triggerAuthRefresh() {
    setState(() => _authRefreshKey++);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkForAndroidUpdateOnce();
    });
  }

  Future<void> _checkForAndroidUpdateOnce() async {
    if (_updateCheckedThisLaunch) return;
    _updateCheckedThisLaunch = true;

    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return;
    }

    final AppUpdateInfo? update = await AppUpdateService.instance
        .checkForUpdate();
    if (!mounted || update == null || !update.updateAvailable) return;

    final bool? shouldUpdate = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) {
        final String latestLabel = update.latestVersion.isEmpty
            ? 'build ${update.latestBuildNumber}'
            : '${update.latestVersion}+${update.latestBuildNumber}';
        final String currentLabel =
            '${update.currentVersion}+${update.currentBuildNumber}';
        return AlertDialog(
          title: const Text('Update available'),
          content: Text(
            'A newer version of FACTS is available.\n\n'
            'Current: $currentLabel\n'
            'Latest:  $latestLabel\n\n'
            'Do you want to download and install the update now?',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Later'),
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
    final String? url = update.preferredUrl;
    if (url == null) return;

    final Uri uri = Uri.parse(url);
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<Map<String, dynamic>> _fetchAuthInfo(User user, int refreshKey) async {
    final bool forceRefresh = refreshKey > 0;
    final IdTokenResult token = await user.getIdTokenResult(forceRefresh);
    final String? role = await UserRoleService.fetchRoleByUid(
      user.uid,
      forceRefresh: forceRefresh,
    );
    final bool isAdmin =
        token.claims != null &&
        (token.claims!['admin'] == true || token.claims!['admin'] == 'true');
    return <String, dynamic>{'isAdmin': isAdmin, 'role': role};
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (BuildContext context, AsyncSnapshot<User?> snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const _AuthLoadingView();
        }

        final User? user = snapshot.data;
        if (user == null) {
          return const LoginPage();
        }

        return FutureBuilder<Map<String, dynamic>>(
          future: _fetchAuthInfo(user, _authRefreshKey),
          builder:
              (
                BuildContext context,
                AsyncSnapshot<Map<String, dynamic>> authSnapshot,
              ) {
                if (authSnapshot.connectionState == ConnectionState.waiting) {
                  return const _AuthLoadingView();
                }
                if (authSnapshot.hasError) {
                  return const _AuthErrorView(
                    message: 'Failed to load your profile. Please try again.',
                  );
                }

                final Map<String, dynamic>? data = authSnapshot.data;
                final bool isAdmin = data?['isAdmin'] == true;
                final String? role = data?['role'] as String?;

                if (kIsWeb &&
                    !isAdmin &&
                    role != 'instructor' &&
                    role != 'admin') {
                  return const _AuthErrorView(
                    message:
                        'Web access is available only for admin and instructor accounts.\n\nPlease use the mobile app for student access.',
                  );
                }

                if (isAdmin) return const AdminPage();

                if (role == 'admin') {
                  return _BootstrapAdminClaimView(
                    user: user,
                    onBootstrapped: _triggerAuthRefresh,
                  );
                }

                if (!user.emailVerified) {
                  final String? destinationRoute = switch (role) {
                    'student' => StudentPage.routeName,
                    'instructor' => InstructorPage.routeName,
                    _ => null,
                  };

                  if (destinationRoute == null) {
                    return const _AuthErrorView(
                      message:
                          'Your account is missing a role assignment. Please contact support.',
                    );
                  }

                  return VerifyEmailPage(destinationRoute: destinationRoute);
                }

                switch (role) {
                  case 'student':
                    return const StudentPage();
                  case 'instructor':
                    return const InstructorPage();
                  default:
                    return const _AuthErrorView(
                      message:
                          'Your account is missing a role assignment. Please contact support.',
                    );
                }
              },
        );
      },
    );
  }
}

class _BootstrapAdminClaimView extends StatefulWidget {
  const _BootstrapAdminClaimView({
    required this.user,
    required this.onBootstrapped,
  });

  final User user;
  final VoidCallback onBootstrapped;

  @override
  State<_BootstrapAdminClaimView> createState() =>
      _BootstrapAdminClaimViewState();
}

class _BootstrapAdminClaimViewState extends State<_BootstrapAdminClaimView> {
  bool _isSubmitting = false;

  Future<void> _enableAdminAccess() async {
    if (_isSubmitting) return;
    setState(() => _isSubmitting = true);
    final messenger = ScaffoldMessenger.of(context);

    try {
      await FirebaseFunctions.instance
          .httpsCallable('bootstrapAdminClaim')
          .call();
      await widget.user.getIdToken(true);
      widget.onBootstrapped();
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Admin access enabled. Loading admin dashboard...'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } on FirebaseFunctionsException catch (error) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(error.message ?? 'Failed to enable admin access.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Failed to enable admin access.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                'Your account is marked as an Admin, but admin privileges are not enabled yet.\n\nTap “Enable admin access” once to activate admin permissions for this account.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _isSubmitting ? null : _enableAdminAccess,
                child: _isSubmitting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Enable admin access'),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () async {
                  final bool shouldSignOut = await showConfirmSignOutDialog(
                    context,
                  );
                  if (!shouldSignOut) return;

                  await FirebaseAuth.instance.signOut();
                },
                child: const Text('Back to login'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AuthLoadingView extends StatelessWidget {
  const _AuthLoadingView();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}

class _AuthErrorView extends StatelessWidget {
  const _AuthErrorView({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                message,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () async {
                  final bool shouldSignOut = await showConfirmSignOutDialog(
                    context,
                  );
                  if (!shouldSignOut) return;

                  await FirebaseAuth.instance.signOut();
                },
                child: const Text('Back to login'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class UnknownRouteScreen extends StatelessWidget {
  const UnknownRouteScreen({super.key, required this.unknownRouteName});

  final String unknownRouteName;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Page not found')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.error_outline, size: 48),
            const SizedBox(height: 16),
            Text('Route "$unknownRouteName" is not defined'),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () => Navigator.of(
                context,
              ).pushReplacementNamed(LoginPage.routeName),
              child: const Text('Back to login'),
            ),
          ],
        ),
      ),
    );
  }
}
