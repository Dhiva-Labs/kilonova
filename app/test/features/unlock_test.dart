import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kilonova/src/rust/api/network.dart';
import 'package:kilonova/src/rust/api/wallets.dart';

import '../helpers/rust.dart';

void main() {
  setUpAll(initRustForTests);

  testWidgets('lock, wrong password, unlock', (tester) async {
    useDesktopWindow(tester);
    await tester.runAsync(() async {
      final seed = await generateSeed(format: SeedFormat.polyseed);
      final wallet = await createWalletFromSeed(
        name: 'Daily',
        network: Network.mainnet,
        mode: SyncMode.lws,
        words: seed.words.join(' '),
        password: 'daily password',
      );
      wallet.lock();
    });
    await tester.pumpWidget(await testApp(tester));

    expect(find.text('Light wallet server'), findsOneWidget);
    await tester.tap(find.text('Daily'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'wrong password');
    await tester.tap(find.widgetWithText(FilledButton, 'Unlock'));
    await pumpUntilFound(
      tester,
      find.text('That password does not open this wallet.'),
    );

    await tester.enterText(find.byType(TextField), 'daily password');
    await tester.tap(find.widgetWithText(FilledButton, 'Unlock'));
    await pumpUntilFound(tester, find.text('Main address'));

    await tester.tap(find.byTooltip('Wallet options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lock'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilledButton, 'Unlock'), findsOneWidget);
  });
}
