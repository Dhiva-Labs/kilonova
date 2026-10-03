import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kilonova/src/rust/api/network.dart';
import 'package:kilonova/src/rust/api/wallets.dart';

import '../../helpers/rust.dart';

const _password = 'coins password';

void main() {
  setUpAll(initRustForTests);

  testWidgets('a fresh wallet has no coins yet', (tester) async {
    useDesktopWindow(tester);
    await tester.runAsync(() async {
      final seed = await generateSeed(format: SeedFormat.polyseed);
      (await createWalletFromSeed(
        name: 'Coinless',
        network: Network.mainnet,
        mode: SyncMode.full,
        words: seed.words.join(' '),
        password: _password,
        createdHere: true,
      )).lock();
    });

    await tester.pumpWidget(await testApp(tester));
    await tester.tap(find.text('Coinless'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), _password);
    await tester.tap(find.widgetWithText(FilledButton, 'Unlock'));
    await pumpUntilFound(tester, find.text('BALANCE'));

    await tester.tap(find.byTooltip('Wallet options'));
    await tester.pumpAndSettle();
    expect(find.text('Coins'), findsOneWidget);
    await tester.tap(find.text('Coins'));
    await tester.pumpAndSettle();

    expect(find.text('This wallet has no coins yet.'), findsOneWidget);
  });
}
