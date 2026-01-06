// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:facts_ui_ux/login.dart';

void main() {
  testWidgets('Login form shows heading and validates inputs', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Center(child: SizedBox(width: 520, child: LoginPage())),
    ));

    expect(find.text('Welcome back'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);

    // Enter invalid email and short password to trigger validators (avoids Firebase calls).
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Email'),
      'invalid-email',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Password'),
      '123',
    );

    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    expect(find.text('Enter a valid email address'), findsOneWidget);
    expect(find.text('Password must be at least 6 characters'), findsOneWidget);
  });
}
