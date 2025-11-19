import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'login.dart';
import 'signup_pickrole.dart';
import 'firebase_options.dart';

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
      initialRoute: LoginPage.routeName,
      routes: <String, WidgetBuilder>{
        LoginPage.routeName: (BuildContext context) => const LoginPage(),
        SignupPickRolePage.routeName: (BuildContext context) =>
            const SignupPickRolePage(),
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
