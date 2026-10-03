import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kilonova/src/rust/api/network.dart';
import 'package:kilonova/src/rust/api/wallets.dart';

import '../../helpers/rust.dart';

const _password = 'book password';

void main() {
  setUpAll(initRustForTests);

  testWidgets('recipients are saved, checked, and picked when sending', (
    tester,
  ) async {
    useDesktopWindow(tester);
    late String friend;
    late String stagenet;
    await tester.runAsync(() async {
      Future<OpenWallet> make(String name, Network network) async {
        final seed = await generateSeed(format: SeedFormat.classic);
        return createWalletFromSeed(
          name: name,
          network: network,
          mode: SyncMode.full,
          words: seed.words.join(' '),
          password: _password,
          createdHere: true,
        );
      }

      (await make('Payer', Network.mainnet)).lock();
      final f = await make('Friend', Network.mainnet);
      friend = f.addresses().first.address;
      f.lock();
      final s = await make('Elsewhere', Network.stagenet);
      stagenet = s.addresses().first.address;
      s.lock();
    });

    await tester.pumpWidget(await testApp(tester));
    await tester.tap(find.text('Payer'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), _password);
    await tester.tap(find.widgetWithText(FilledButton, 'Unlock'));
    await pumpUntilFound(tester, find.text('BALANCE'));

    await tester.tap(find.byTooltip('Wallet options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Address book'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No saved recipients yet'), findsOneWidget);

    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    await tester.enterText(fieldWithLabel('Name'), 'Ana');
    await tester.enterText(fieldWithLabel('To'), stagenet);
    await tester.tap(find.text('Save'));
    await pumpUntilFound(
      tester,
      find.text('This is not a valid address for this network.'),
    );
    await tester.enterText(fieldWithLabel('To'), friend);
    await tester.tap(find.text('Save'));
    await pumpUntilFound(tester, find.text('Ana'));
    await tester.pageBack();
    await tester.pumpAndSettle();

    // Back on the wallet page, which rebuilds from async calls into the
    // core: wait for each control rather than assume one settle is enough.
    final send = find.widgetWithText(FilledButton, 'Send');
    await pumpUntilFound(tester, send);
    await tester.tap(send);
    await tester.pumpAndSettle();
    final pick = find.byTooltip('Choose from address book');
    await pumpUntilFound(tester, pick);
    await tester.tap(pick);
    await tester.pumpAndSettle();
    await pumpUntilFound(tester, find.text('Ana'));
    await tester.tap(find.text('Ana'));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(fieldWithLabel('To'));
    expect(field.controller!.text, friend);
  });
}
