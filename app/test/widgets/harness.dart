import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kilonova/theme/theme.dart';

/// Pumps [child] in the app theme, without the Rust core.
Future<void> pumpThemed(
  WidgetTester tester,
  Widget child, {
  Brightness brightness = Brightness.light,
}) => tester.pumpWidget(
  MaterialApp(
    theme: buildTheme(brightness),
    home: Scaffold(
      body: Padding(padding: const EdgeInsets.all(16), child: child),
    ),
  ),
);
