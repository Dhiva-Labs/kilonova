import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/rust.dart';

/// The stagenet wallet monero-wallet-rpc created for kn-keys' vectors.
Map<String, dynamic> stagenetVector() {
  final json =
      jsonDecode(File('../core/kn-keys/tests/vectors.json').readAsStringSync())
          as Map<String, dynamic>;
  final networks = (json['networks'] as List).cast<Map<String, dynamic>>();
  return networks.firstWhere((n) => n['network'] == 'stagenet')['classic']
      as Map<String, dynamic>;
}

Future<void> openRestore(WidgetTester tester) async {
  await tester.tap(find.text('Stagenet'));
  await tester.pumpAndSettle();
  // Through the add menu, which exists whether or not wallets do.
  await tester.tap(find.byTooltip('Add a wallet'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Restore wallet').last);
  await tester.pumpAndSettle();
}

/// The form is taller than the window; bring each target into view first.
Future<void> fill(WidgetTester tester, String label, String value) async {
  final field = find.widgetWithText(TextFormField, label);
  await tester.ensureVisible(field);
  await tester.enterText(field, value);
}

Future<void> submit(WidgetTester tester) async {
  final button = find.widgetWithText(FilledButton, 'Restore wallet');
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
}

void main() {
  setUpAll(initRustForTests);

  testWidgets('restoring a reference seed shows the reference addresses', (
    tester,
  ) async {
    useDesktopWindow(tester);
    final vector = stagenetVector();
    await tester.pumpWidget(await testApp(tester));
    await openRestore(tester);

    await fill(tester, 'Wallet name', 'Restored');
    await fill(tester, 'Seed words', vector['mnemonic'] as String);
    await fill(tester, 'Restore height (optional)', '1200000');
    await fill(tester, 'Password', 'restore pw');
    await fill(tester, 'Confirm password', 'restore pw');
    await submit(tester);
    await pumpUntilFound(tester, find.text('Balance'));

    expect(find.text(vector['address'] as String), findsOneWidget);

    // The next subaddress matches monero-wallet-rpc's 0/1.
    await tester.tap(find.text('New address'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Rent');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await pumpUntilFound(tester, find.text('Address 1 · Rent'));
    final sub = (vector['subaddresses'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((s) => s['account'] == 0 && s['index'] == 1);
    expect(find.text(sub['address'] as String), findsOneWidget);
  });

  testWidgets('a bad seed is explained, and nothing is created', (
    tester,
  ) async {
    useDesktopWindow(tester);
    final words = (stagenetVector()['mnemonic'] as String).split(' ');
    await tester.pumpWidget(await testApp(tester));
    await openRestore(tester);

    await fill(tester, 'Wallet name', 'Broken');
    await fill(tester, 'Seed words', words.take(24).join(' '));
    await fill(tester, 'Password', 'restore pw');
    await fill(tester, 'Confirm password', 'restore pw');
    await submit(tester);
    await pumpUntilFound(
      tester,
      find.text('A seed has 25 words, or 16 for Polyseed.'),
    );
    expect(find.text('Restore wallet'), findsWidgets);
  });

  testWidgets('view-only restore rejects a view key for another address', (
    tester,
  ) async {
    useDesktopWindow(tester);
    final vector = stagenetVector();
    await tester.pumpWidget(await testApp(tester));
    await openRestore(tester);

    await tester.tap(find.text('View-only'));
    await tester.pumpAndSettle();
    await fill(tester, 'Wallet name', 'Watch');
    await fill(tester, 'Main address', vector['address'] as String);
    // Valid as a key (below the group order), but not this wallet's.
    await fill(tester, 'Private view key', '01' * 32);
    await fill(tester, 'Password', 'restore pw');
    await fill(tester, 'Confirm password', 'restore pw');
    await submit(tester);
    await pumpUntilFound(
      tester,
      find.text('This view key does not belong to this address.'),
    );
  });
}
