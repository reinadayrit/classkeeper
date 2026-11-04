import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Helper function to test business logic independently
String generateDefaultPassword(String fullName, String schoolId) {
  String lastName = '';
  final trimmedName = fullName.trim();

  if (trimmedName.contains(',')) {
    lastName = trimmedName.split(',').first.trim();
  } else {
    final parts = trimmedName.split(RegExp(r'\s+'));
    lastName = parts.isNotEmpty ? parts.last : trimmedName;
  }

  if (lastName.isNotEmpty) {
    lastName = lastName[0].toUpperCase() + lastName.substring(1).toLowerCase();
  } else {
    lastName = 'Student';
  }

  final digits = schoolId.replaceAll(RegExp(r'\D'), '');
  final last6 = digits.length >= 6
      ? digits.substring(digits.length - 6)
      : digits.padLeft(6, '0');

  return '$lastName$last6';
}

void main() {
  group('Unit Tests - Logic & Utility Functions', () {
    test(
        'generateDefaultPassword creates correct password from full name and ID',
        () {
      final password = generateDefaultPassword('Reyes, Gabriel', '02000139801');
      expect(password, equals('Reyes139801'));
    });

    test('generateDefaultPassword handles single names correctly', () {
      final password = generateDefaultPassword('Gabriel', '123456');
      expect(password, equals('Gabriel123456'));
    });
  });

  group('Widget Tests - UI Interactions', () {
    testWidgets('Renders Login Form correctly and accepts text input',
        (WidgetTester tester) async {
      // Build a testable Login Form Widget in isolation
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                children: [
                  const Text('ClassKeeper Login',
                      style: TextStyle(fontSize: 20)),
                  const TextField(
                    key: Key('email_field'),
                    decoration: InputDecoration(hintText: 'Enter Email'),
                  ),
                  const TextField(
                    key: Key('password_field'),
                    obscureText: true,
                    decoration: InputDecoration(hintText: 'Enter Password'),
                  ),
                  ElevatedButton(
                    onPressed: () {},
                    child: const Text('Sign In'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      // 1. Verify static elements are visible on screen
      expect(find.text('ClassKeeper Login'), findsOneWidget);
      expect(find.text('Sign In'), findsOneWidget);

      // 2. Simulate user typing into text fields
      await tester.enterText(
          find.byKey(const Key('email_field')), 'faculty@classkeeper.edu');
      await tester.enterText(
          find.byKey(const Key('password_field')), 'password123');

      // 3. Verify text was correctly entered
      expect(find.text('faculty@classkeeper.edu'), findsOneWidget);
      expect(find.text('password123'), findsOneWidget);
    });

    testWidgets('Tapping Sign In button triggers action',
        (WidgetTester tester) async {
      bool buttonPressed = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ElevatedButton(
              onPressed: () {
                buttonPressed = true;
              },
              child: const Text('Submit'),
            ),
          ),
        ),
      );

      // Verify initial state
      expect(buttonPressed, isFalse);

      // Tap the button and settle animations
      await tester.tap(find.byType(ElevatedButton));
      await tester.pumpAndSettle();

      // Verify button tap changed state
      expect(buttonPressed, isTrue);
    });
  });
}
