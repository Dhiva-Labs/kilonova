import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kilonova/widgets/test_network_strip.dart';

import '../helpers/rust.dart';

/// These tests use the phone layout (app bar, single pane).
void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  setUpAll(initRustForTests);

  testWidgets('empty mainnet offers create and restore, no strip', (
    tester,
  ) async {
    _phone(tester);
    await tester.pumpWidget(await testApp(tester));

    expect(find.text('No Mainnet wallets yet'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Create wallet'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Restore wallet'), findsOneWidget);
    expect(find.textContaining('These coins have no value'), findsNothing);
  });

  testWidgets('switching to stagenet shows the strip', (tester) async {
    _phone(tester);
    await tester.pumpWidget(await testApp(tester));

    await chooseNetwork(tester, 'Stagenet');

    expect(find.text('No Stagenet wallets yet'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(TestNetworkStrip),
        matching: find.text('Stagenet. These coins have no value.'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('about screen shows the core version', (tester) async {
    _phone(tester);
    await tester.pumpWidget(await testApp(tester));

    await openSettings(tester);
    // Settings is a lazy list; on a phone, About is below the fold.
    await tester.scrollUntilVisible(find.text('About Kilonova'), 200);
    await tester.pumpAndSettle();
    await tester.tap(find.text('About Kilonova'));
    await tester.pumpAndSettle();

    expect(find.text('0.3.0'), findsOneWidget);
  });
}
