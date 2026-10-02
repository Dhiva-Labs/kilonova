import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kilonova/src/rust/api/network.dart';
import 'package:kilonova/src/rust/api/wallets.dart';

import '../../helpers/rust.dart';

const _password = 'send password';

/// Opens a fresh mainnet full-mode wallet. Its node is the closed local
/// port from [initRustForTests], so it never finishes syncing.
Future<String> _openWallet(WidgetTester tester, String name) async {
  late String address;
  await tester.runAsync(() async {
    final seed = await generateSeed(format: SeedFormat.classic);
    final wallet = await createWalletFromSeed(
      name: name,
      network: Network.mainnet,
      mode: SyncMode.full,
      words: seed.words.join(' '),
      password: _password,
      createdHere: true,
    );
    address = wallet.addresses().first.address;
    wallet.lock();
  });
  await tester.pumpWidget(await testApp(tester));
  await tester.tap(find.text(name));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField), _password);
  await tester.tap(find.widgetWithText(FilledButton, 'Unlock'));
  await pumpUntilFound(tester, find.text('Balance'));
  return address;
}

Finder _field(String label) => find.widgetWithText(TextField, label);

void main() {
  setUpAll(initRustForTests);

  testWidgets('checks addresses and amounts before building anything', (
    tester,
  ) async {
    useDesktopWindow(tester);
    final own = await _openWallet(tester, 'Checks');
    await tester.tap(find.widgetWithText(FilledButton, 'Send'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Review'));
    await tester.pumpAndSettle();
    expect(find.text('Enter an address'), findsOneWidget);
    expect(
      find.text('Enter an amount above zero, with at most 12 decimals'),
      findsOneWidget,
    );

    // A stagenet address on a mainnet wallet.
    late String stagenet;
    await tester.runAsync(() async {
      final seed = await generateSeed(format: SeedFormat.classic);
      final w = await createWalletFromSeed(
        name: 'Other network',
        network: Network.stagenet,
        mode: SyncMode.full,
        words: seed.words.join(' '),
        password: _password,
        createdHere: true,
      );
      stagenet = w.addresses().first.address;
      w.lock();
    });
    await tester.enterText(_field('Recipient address'), stagenet);
    await tester.enterText(_field('Amount'), '1.0000000000001');
    await tester.tap(find.text('Review'));
    await tester.pumpAndSettle();
    expect(
      find.text("Not a valid address for this wallet's network"),
      findsOneWidget,
    );
    expect(
      find.text('Enter an amount above zero, with at most 12 decimals'),
      findsOneWidget,
    );

    // Valid input, but the wallet never caught up with its node.
    await tester.enterText(_field('Recipient address'), own);
    await tester.enterText(_field('Amount'), '0.5');
    await tester.tap(find.text('Review'));
    await pumpUntilFound(
      tester,
      find.text('Wait until the wallet is up to date, then try again.'),
    );
    expect(find.text('Check before sending'), findsNothing);
  });

  testWidgets('a pasted monero: request fills in the recipients', (
    tester,
  ) async {
    useDesktopWindow(tester);
    final own = await _openWallet(tester, 'Paste');
    await tester.tap(find.widgetWithText(FilledButton, 'Send'));
    await tester.pumpAndSettle();

    final clipboard = 'monero:$own;$own?tx_amount=0.25;1&recipient_name=Shop';
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async => call.method == 'Clipboard.getData'
          ? <String, dynamic>{'text': clipboard}
          : null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.tap(find.byTooltip('Paste'));
    await tester.pumpAndSettle();

    expect(find.text('Recipient 1'), findsOneWidget);
    expect(find.text('Recipient 2'), findsOneWidget);
    expect(find.text('0.25'), findsOneWidget);
    expect(find.text('1.0'), findsOneWidget);
    expect(find.text('Payment request: Shop'), findsOneWidget);
  });

  testWidgets('receive addresses show as a QR code', (tester) async {
    useDesktopWindow(tester);
    final own = await _openWallet(tester, 'QR');
    await tester.tap(find.byTooltip('Show QR code').first);
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel(own), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
  });

  testWidgets('the form fits a phone screen', (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _openWallet(tester, 'Phone');
    await tester.tap(find.widgetWithText(FilledButton, 'Send'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add a recipient'));
    await tester.tap(find.text('Urgent'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
