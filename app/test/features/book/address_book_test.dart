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
    await pumpUntilFound(tester, find.text('Balance'));

    await tester.tap(find.byTooltip('Wallet options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Address book'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No saved recipients yet'), findsOneWidget);

    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Ana');
    await tester.enterText(
      find.widgetWithText(TextField, 'Recipient address'),
      stagenet,
    );
    await tester.tap(find.text('Save'));
    await pumpUntilFound(
      tester,
      find.text('This is not a valid address for this network.'),
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Recipient address'),
      friend,
    );
    await tester.tap(find.text('Save'));
    await pumpUntilFound(tester, find.text('Ana'));
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Send'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Choose from address book'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ana'));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(
      find.widgetWithText(TextField, 'Recipient address'),
    );
    expect(field.controller!.text, friend);
  });
}
