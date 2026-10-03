import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kilonova/src/rust/api/network.dart';
import 'package:kilonova/src/rust/api/wallets.dart';

import '../../helpers/rust.dart';

const _password = 'request password';

void main() {
  setUpAll(initRustForTests);

  testWidgets('create a request, see it on the wallet page, open and delete it', (
    tester,
  ) async {
    useDesktopWindow(tester);
    await tester.runAsync(() async {
      final seed = await generateSeed(format: SeedFormat.polyseed);
      (await createWalletFromSeed(
        name: 'Requester',
        network: Network.mainnet,
        mode: SyncMode.full,
        words: seed.words.join(' '),
        password: _password,
        createdHere: true,
      )).lock();
    });

    await tester.pumpWidget(await testApp(tester));
    await tester.tap(find.text('Requester'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), _password);
    await tester.tap(find.widgetWithText(FilledButton, 'Unlock'));
    await pumpUntilFound(tester, find.text('BALANCE'));

    await tester.tap(find.widgetWithText(FilledButton, 'Receive'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Request a payment'));
    await tester.pumpAndSettle();

    await tester.enterText(fieldWithLabel('Amount'), '0.25');
    await tester.enterText(fieldWithLabel('What it is for'), 'Coffee');
    await tester.tap(find.widgetWithText(FilledButton, 'Create request'));
    await pumpUntilFound(tester, find.text('Waiting'));
    expect(find.text('Coffee'), findsWidgets);

    // Back out of the request screen, then the receive dialog.
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    // The wallet page refreshes on sync events; re-selecting it forces a
    // rebuild without waiting for one.
    await tester.tap(find.text('Requester').first);
    await tester.pumpAndSettle();

    expect(find.text('REQUESTS'), findsOneWidget);
    expect(find.text('Coffee'), findsOneWidget);
    expect(find.text('Waiting'), findsOneWidget);

    await tester.tap(find.text('Coffee'));
    await pumpUntilFound(tester, find.text('Delete request'));
    await tester.tap(find.text('Delete request'));
    await pumpUntil(
      tester,
      () => find.text('REQUESTS').evaluate().isEmpty,
      what: 'the request list to update',
    );
    await tester.pumpAndSettle();
    expect(find.text('Coffee'), findsNothing);
  });
}
