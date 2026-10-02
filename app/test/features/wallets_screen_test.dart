import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kilonova/app.dart';
import 'package:kilonova/widgets/test_network_strip.dart';

import '../helpers/rust.dart';

void main() {
  setUpAll(initRustForTests);

  testWidgets('mainnet shows no test-network strip', (tester) async {
    await tester.pumpWidget(const KilonovaApp());

    expect(find.text('No Mainnet wallets yet'), findsOneWidget);
    expect(find.textContaining('These coins have no value'), findsNothing);
  });

  testWidgets('switching to stagenet shows the strip', (tester) async {
    await tester.pumpWidget(const KilonovaApp());

    await tester.tap(find.text('Stagenet'));
    await tester.pump();

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
    await tester.pumpWidget(const KilonovaApp());

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('About Kilonova'));
    await tester.pumpAndSettle();

    expect(find.text('0.1.0'), findsOneWidget);
    expect(find.byType(SelectableText), findsWidgets);
  });
}
