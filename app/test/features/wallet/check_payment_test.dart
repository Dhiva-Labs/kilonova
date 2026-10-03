import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kilonova/src/rust/api/network.dart';
import 'package:kilonova/src/rust/api/wallets.dart';

import '../../helpers/rust.dart';

const _password = 'check payment password';

void main() {
  setUpAll(initRustForTests);

  testWidgets('a bad transaction id shows its error', (tester) async {
    useDesktopWindow(tester);
    await tester.runAsync(() async {
      final seed = await generateSeed(format: SeedFormat.polyseed);
      (await createWalletFromSeed(
        name: 'Checker',
        network: Network.mainnet,
        mode: SyncMode.full,
        words: seed.words.join(' '),
        password: _password,
        createdHere: true,
      )).lock();
    });

    await tester.pumpWidget(await testApp(tester));
    await tester.tap(find.text('Checker'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), _password);
    await tester.tap(find.widgetWithText(FilledButton, 'Unlock'));
    await pumpUntilFound(tester, find.text('BALANCE'));

    await tester.tap(find.byTooltip('Wallet options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Check a payment'));
    await tester.pumpAndSettle();

    await tester.enterText(fieldWithLabel('Transaction ID'), 'not-a-txid');
    await tester.enterText(fieldWithLabel('Transaction key'), 'a' * 64);
    await tester.tap(find.widgetWithText(FilledButton, 'Check'));
    await pumpUntilFound(tester, find.text('Not a valid transaction id.'));
  });
}
