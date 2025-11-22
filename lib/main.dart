import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'admin_page.dart';
import 'face_enrollment_page.dart';
import 'firebase_options.dart';
import 'instructor_page.dart';
import 'login.dart';
import 'signup_pickrole.dart';
import 'student_page.dart';
import 'attendance_session_page.dart';
import 'constants/auth_constants.dart';
import 'services/user_role_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const MyApp());
}

class FactsApp extends StatelessWidget {
  const FactsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Facts UI/UX',
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
        AdminPage.routeName: (BuildContext context) => const AdminPage(),
        StudentPage.routeName: (BuildContext context) => const StudentPage(),
        InstructorPage.routeName: (BuildContext context) =>
            const InstructorPage(),
        FaceEnrollmentPage.routeName: (BuildContext context) =>
          const FaceEnrollmentPage(),
          AttendanceSessionPage.routeName: (BuildContext context) {
            final ModalRoute<dynamic>? route = ModalRoute.of(context);
            final AttendanceSessionConfig? config =
                route?.settings.arguments as AttendanceSessionConfig?;
            if (config == null) {
              return const UnknownRouteScreen(
                unknownRouteName: AttendanceSessionPage.routeName,
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

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

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

        final String normalizedAdminEmail = kAdminEmail.toLowerCase();
        if ((user.email ?? '').toLowerCase() == normalizedAdminEmail) {
          return const AdminPage();
        }

        return FutureBuilder<String?>(
          future: UserRoleService.fetchRoleByUid(user.uid),
          builder: (BuildContext context, AsyncSnapshot<String?> roleSnapshot) {
            if (roleSnapshot.connectionState == ConnectionState.waiting) {
              return const _AuthLoadingView();
            }
            if (roleSnapshot.hasError) {
              return const _AuthErrorView(
                message: 'Failed to load your profile. Please try again.',
              );
            }
            final String? role = roleSnapshot.data;
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
