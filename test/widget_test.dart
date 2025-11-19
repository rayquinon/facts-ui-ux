// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:facts_ui_ux/main.dart';

void main() {
  testWidgets('Login form validates and submits', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());

    expect(find.text('Welcome back'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Email'),
      'user@example.com',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Password'),
      'secret123',
    );

    await tester.tap(find.text('Sign in'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    expect(find.textContaining('Welcome user@example.com'), findsOneWidget);
  });
}
