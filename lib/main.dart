import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
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
import 'reset_password_page.dart';
import 'verify_email_page.dart';
import 'verify_phone_page.dart';
import 'auth_action_page.dart';
import 'notifications_page.dart';
import 'widgets/confirm_sign_out_dialog.dart';
import 'widgets/android_only_feature_page.dart';

final GlobalKey<NavigatorState> _rootNavigatorKey = GlobalKey<NavigatorState>();

class _StudentInactivityLogoutController with WidgetsBindingObserver {
  _StudentInactivityLogoutController._();

  static final _StudentInactivityLogoutController instance =
      _StudentInactivityLogoutController._();

  static const Duration _timeout = Duration(minutes: 15);
  static const Duration _minResetInterval = Duration(milliseconds: 250);

  bool _enabled = false;
  bool _loggingOut = false;
  bool _promptVisible = false;
  Timer? _timer;
  DateTime _lastInteractionAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastResetAt = DateTime.fromMillisecondsSinceEpoch(0);

  void enable() {
    if (_enabled) return;
    _enabled = true;
    _loggingOut = false;
    _lastInteractionAt = DateTime.now();
    _lastResetAt = _lastInteractionAt;
    WidgetsBinding.instance.addObserver(this);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_handlePointerEvent);
    _scheduleTimer();
  }

  void disable() {
    if (!_enabled) return;
    _enabled = false;
    _loggingOut = false;
    _timer?.cancel();
    _timer = null;
    WidgetsBinding.instance.removeObserver(this);
    GestureBinding.instance.pointerRouter.removeGlobalRoute(
      _handlePointerEvent,
    );
  }

  void _handlePointerEvent(PointerEvent event) {
    if (!_enabled || _loggingOut || _promptVisible) return;
    if (event is PointerDownEvent || event is PointerSignalEvent) {
      _bump();
    }
  }

  void _bump() {
    if (_promptVisible) return;
    final DateTime now = DateTime.now();
    if (now.difference(_lastResetAt) < _minResetInterval) return;
    _lastResetAt = now;
    _lastInteractionAt = now;
    _scheduleTimer();
  }

  void _scheduleTimer() {
    _timer?.cancel();
    if (!_enabled) return;
    final DateTime now = DateTime.now();
    final Duration elapsed = now.difference(_lastInteractionAt);
    final Duration remaining = _timeout - elapsed;
    if (remaining <= Duration.zero) {
      _timer = Timer(Duration.zero, _onTimeout);
      return;
    }
    _timer = Timer(remaining, _onTimeout);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_enabled || _loggingOut) return;
    if (state == AppLifecycleState.resumed) {
      final DateTime now = DateTime.now();
      if (!_promptVisible && now.difference(_lastInteractionAt) >= _timeout) {
        _onTimeout();
      } else if (!_promptVisible) {
        _scheduleTimer();
      }
    }
  }

  void _onTimeout() {
    if (!_enabled || _loggingOut || _promptVisible) return;
    _showSessionExpiredPrompt();
  }

  Future<void> _showSessionExpiredPrompt() async {
    if (!_enabled || _loggingOut || _promptVisible) return;
    _promptVisible = true;
    _timer?.cancel();
    _timer = null;

    final BuildContext? context = _rootNavigatorKey.currentContext;
    if (context == null) {
      // No context yet; try again soon.
      _promptVisible = false;
      _scheduleTimer();
      return;
    }

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return PopScope(
          canPop: false,
          child: AlertDialog(
            title: const Text('Session expired'),
            content: const Text(
              'You have been inactive for 15 minutes. For your account security, please log in again.',
            ),
            actions: <Widget>[
              FilledButton(
                onPressed: () async {
                  Navigator.of(dialogContext).pop();
                  await _logoutNow();
                },
                child: const Text('Log out'),
              ),
            ],
          ),
        );
      },
    );

    // If the dialog closed without logging out (should not happen), resume timer.
    if (_enabled && !_loggingOut) {
      _promptVisible = false;
      _lastInteractionAt = DateTime.now();
      _scheduleTimer();
    }
  }

  Future<void> _logoutNow() async {
    if (!_enabled || _loggingOut) return;
    _loggingOut = true;
    try {
      await FirebaseAuth.instance.signOut();
    } catch (_) {
      // Best-effort only.
    }

    final NavigatorState? nav = _rootNavigatorKey.currentState;
    if (nav != null) {
      try {
        nav.pushNamedAndRemoveUntil(LoginPage.routeName, (_) => false);
      } catch (_) {
        // AuthGate will still react to signOut.
      }
    }
    _loggingOut = false;
    _promptVisible = false;
  }
}

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

  static const Color _brandNavy = Color(0xFF1A1851);
  static const Color _brandGold = Color(0xFFFCB315);

  static ColorScheme _buildColorScheme() {
    // Claymorphism works best with a dark, slightly colored base and warm accent.
    // Keep contrast high and avoid pure white; use a warm off-white for text.
    final Color onDark = Colors.white.withValues(alpha: 0.92);
    final Color onDarkMuted = Colors.white.withValues(alpha: 0.70);

    final ColorScheme base = ColorScheme.dark(
      primary: _brandGold,
      onPrimary: _brandNavy,
      secondary: _brandGold,
      onSecondary: _brandNavy,
      surface: _brandNavy,
      onSurface: onDark,
      outline: Colors.white.withValues(alpha: 0.18),
      error: const Color(0xFFFF6B6B),
      onError: Colors.black,
    );

    return base.copyWith(
      surfaceContainerHighest: const Color(0xFF24225F),
      onSurfaceVariant: onDarkMuted,
    );
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = _buildColorScheme();
    final Color offWhite = scheme.onSurface;
    final Color muted = scheme.onSurface.withValues(alpha: 0.70);
    final Color claySurface = scheme.surfaceContainerHighest;
    final Color clayShadow = Colors.black.withValues(alpha: 0.38);
    final Color clayHighlight = Colors.white.withValues(alpha: 0.08);

    return MaterialApp(
      navigatorKey: _rootNavigatorKey,
      title: 'Facts',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: scheme,
        visualDensity: VisualDensity.adaptivePlatformDensity,
        useMaterial3: true,
        scaffoldBackgroundColor: scheme.surface,
        canvasColor: scheme.surface,
        shadowColor: clayShadow,
        textTheme: ThemeData.dark().textTheme.apply(
          bodyColor: offWhite,
          displayColor: offWhite,
        ),
        appBarTheme: AppBarTheme(
          backgroundColor: scheme.surface,
          foregroundColor: offWhite,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          titleTextStyle: ThemeData.dark().textTheme.titleLarge?.copyWith(
            color: offWhite,
            fontWeight: FontWeight.w700,
          ),
        ),
        cardTheme: CardThemeData(
          color: claySurface,
          elevation: 0,
          shadowColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: BorderSide(color: scheme.outline),
          ),
          // Avoid a global Card margin: many screens already add padding/margins,
          // and a large default margin can cause cramped layouts/overflow.
          margin: EdgeInsets.zero,
        ),
        dialogTheme: DialogThemeData(
          backgroundColor: claySurface,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: BorderSide(color: scheme.outline),
          ),
          titleTextStyle: ThemeData.dark().textTheme.titleMedium?.copyWith(
            color: offWhite,
            fontWeight: FontWeight.w700,
          ),
          contentTextStyle: ThemeData.dark().textTheme.bodyMedium?.copyWith(
            color: offWhite,
          ),
        ),
        snackBarTheme: SnackBarThemeData(
          backgroundColor: claySurface,
          contentTextStyle: ThemeData.dark().textTheme.bodyMedium?.copyWith(
            color: offWhite,
          ),
          actionTextColor: scheme.primary,
          behavior: SnackBarBehavior.floating,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: scheme.primary,
            foregroundColor: scheme.onPrimary,
            textStyle: const TextStyle(fontWeight: FontWeight.w700),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: offWhite,
            side: BorderSide(color: scheme.outline),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            foregroundColor: scheme.primary,
            textStyle: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: claySurface,
          hintStyle: TextStyle(color: muted),
          labelStyle: TextStyle(color: offWhite),
          helperStyle: TextStyle(color: muted),
          errorStyle: const TextStyle(color: Color(0xFFFFA3A3)),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: BorderSide(color: scheme.outline),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: BorderSide(color: scheme.primary, width: 2),
          ),
          errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: BorderSide(color: scheme.error),
          ),
          focusedErrorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: BorderSide(color: scheme.error, width: 2),
          ),
        ),
        dividerTheme: DividerThemeData(
          color: scheme.outline.withValues(alpha: 0.9),
          thickness: 1,
          space: 1,
        ),
        iconTheme: IconThemeData(color: offWhite.withValues(alpha: 0.90)),
        floatingActionButtonTheme: FloatingActionButtonThemeData(
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: clayHighlight),
          ),
        ),
        listTileTheme: ListTileThemeData(
          iconColor: offWhite.withValues(alpha: 0.90),
          textColor: offWhite,
        ),
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
      onGenerateRoute: (RouteSettings settings) {
        final String? name = settings.name;
        if (name == null || name.isEmpty) return null;

        Uri? uri;
        try {
          uri = Uri.parse(name);
        } catch (_) {
          return null;
        }

        if (uri.path == '/__/auth/action' || uri.path == '/_/auth/action') {
          return MaterialPageRoute<void>(
            builder: (BuildContext context) => AuthActionPage(uri: uri!),
            settings: settings,
          );
        }

        return null;
      },
      routes: <String, WidgetBuilder>{
        LoginPage.routeName: (BuildContext context) => const LoginPage(),
        SignupPickRolePage.routeName: (BuildContext context) =>
            const SignupPickRolePage(),
        NotificationsPage.routeName: (BuildContext context) =>
            const NotificationsPage(),
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
        ResetPasswordPage.routeName: (BuildContext context) {
          final ModalRoute<dynamic>? route = ModalRoute.of(context);
          final ResetPasswordPageArgs? args =
              route?.settings.arguments as ResetPasswordPageArgs?;
          return ResetPasswordPage(oobCode: args?.oobCode ?? '');
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
  StreamSubscription<Uri>? _appLinksSub;
  String? _lastHandledDeepLink;
  DateTime? _lastHandledDeepLinkAt;
  static const Duration _deepLinkDedupeWindow = Duration(seconds: 2);

  void _triggerAuthRefresh() {
    setState(() => _authRefreshKey++);
  }

  @override
  void initState() {
    super.initState();
    _initAppLinks();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkForAndroidUpdateOnce();
    });
  }

  void _initAppLinks() {
    if (kIsWeb) return;

    final AppLinks appLinks = AppLinks();

    _appLinksSub?.cancel();
    _appLinksSub = appLinks.uriLinkStream.listen(
      (Uri uri) {
        _handleIncomingLink(uri);
      },
      onError: (_) {
        // Ignore link stream errors.
      },
    );

    appLinks
        .getInitialLink()
        .then((Uri? uri) {
          if (uri != null) _handleIncomingLink(uri);
        })
        .catchError((_) {
          // Ignore.
        });
  }

  void _handleIncomingLink(Uri uri) {
    final DateTime now = DateTime.now();
    final String rawIncoming = uri.toString();
    final DateTime? lastAt = _lastHandledDeepLinkAt;
    if (_lastHandledDeepLink == rawIncoming &&
        lastAt != null &&
        now.difference(lastAt) < _deepLinkDedupeWindow) {
      return;
    }
    _lastHandledDeepLink = rawIncoming;
    _lastHandledDeepLinkAt = now;

    Uri effectiveUri = uri;
    final String host = uri.host.toLowerCase();

    // If the link is a Firebase Dynamic Link (page.link), unwrap the actual deep link.
    if (host.endsWith('.page.link')) {
      final String raw = uri.queryParameters['link'] ?? '';
      if (raw.isNotEmpty) {
        try {
          effectiveUri = Uri.parse(raw);
        } catch (_) {
          return;
        }
      } else {
        return;
      }
    }

    final String effectiveHost = effectiveUri.host.toLowerCase();
    final String path = effectiveUri.path;
    const Set<String> allowedHosts = <String>{
      'facts.shiro.codes',
      'simple-distributed-database.web.app',
      'simple-distributed-database.firebaseapp.com',
    };
    if (!allowedHosts.contains(effectiveHost)) return;
    final bool isResetPath = path.startsWith('/reset');
    final bool isFirebaseActionPath =
        path.startsWith('/__/auth/action') || path.startsWith('/_/auth/action');
    if (!isResetPath && !isFirebaseActionPath) return;

    final String mode = (effectiveUri.queryParameters['mode'] ?? '').trim();
    final String code =
        (effectiveUri.queryParameters['oobCode'] ??
                effectiveUri.queryParameters['oob'] ??
                '')
            .trim();
    if (code.isEmpty) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Only route into password reset while signed out.
      // Otherwise, Android may re-deliver the initial reset link on app restart,
      // causing a confusing loop back to the reset screen after login.
      if (isResetPath || mode == 'resetPassword') {
        final User? currentUser = FirebaseAuth.instance.currentUser;
        if (currentUser != null) return;
        _rootNavigatorKey.currentState?.pushNamed(
          ResetPasswordPage.routeName,
          arguments: ResetPasswordPageArgs(oobCode: code),
        );
        return;
      }

      // Let onGenerateRoute parse the full auth action URL.
      if (isFirebaseActionPath) {
        _rootNavigatorKey.currentState?.pushNamed(effectiveUri.toString());
      }
    });
  }

  @override
  void dispose() {
    _appLinksSub?.cancel();
    super.dispose();
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
      attemptRepairIfMissing: true,
    );

    final Map<String, Object?> claims = token.claims == null
        ? <String, Object?>{}
        : token.claims!;
    final bool isAdmin =
        claims['admin'] == true || claims['admin']?.toString() == 'true';
    final bool isInstructor =
        claims['instructor'] == true ||
        claims['instructor']?.toString() == 'true';

    // If Firestore role is missing (common for legacy/mismatched profiles),
    // fall back to custom claims so approved instructors can get in.
    final String? resolvedRole = role ?? (isInstructor ? 'instructor' : null);

    // Best-effort: write the resolved role back to Firestore so other parts
    // of the app that query by `role` behave correctly.
    if (role == null && resolvedRole != null) {
      try {
        await FirebaseFirestore.instance.collection('users').doc(user.uid).set(
          <String, dynamic>{'role': resolvedRole},
          SetOptions(merge: true),
        );
      } catch (_) {
        // Best-effort; continue.
      }
    }

    return <String, dynamic>{'isAdmin': isAdmin, 'role': resolvedRole};
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (BuildContext context, AsyncSnapshot<User?> snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          _StudentInactivityLogoutController.instance.disable();
          return const _AuthLoadingView();
        }

        final User? user = snapshot.data;
        if (user == null) {
          _StudentInactivityLogoutController.instance.disable();
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
                  _StudentInactivityLogoutController.instance.disable();
                  return const _AuthErrorView(
                    message:
                        'Web access is available only for admin and instructor accounts.\n\nPlease use the mobile app for student access.',
                  );
                }

                if (isAdmin) {
                  _StudentInactivityLogoutController.instance.disable();
                  return const AdminPage();
                }

                if (role == 'admin') {
                  _StudentInactivityLogoutController.instance.disable();
                  return _BootstrapAdminClaimView(
                    user: user,
                    onBootstrapped: _triggerAuthRefresh,
                  );
                }

                if (!user.emailVerified) {
                  _StudentInactivityLogoutController.instance.disable();
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
                    _StudentInactivityLogoutController.instance.enable();
                    if ((user.phoneNumber ?? '').isEmpty) {
                      return VerifyPhonePage(onVerified: _triggerAuthRefresh);
                    }
                    return const StudentPage();
                  case 'instructor':
                    _StudentInactivityLogoutController.instance.disable();
                    if ((user.phoneNumber ?? '').isEmpty) {
                      return VerifyPhonePage(onVerified: _triggerAuthRefresh);
                    }
                    return const InstructorPage();
                  default:
                    _StudentInactivityLogoutController.instance.disable();
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
