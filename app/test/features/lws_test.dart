import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kilonova/src/rust/api/network.dart';
import 'package:kilonova/src/rust/api/nodes.dart';
import 'package:kilonova/src/rust/api/wallets.dart';

import '../helpers/rust.dart';

const _password = 'lws password';

Future<OpenWallet> _lwsWallet(WidgetTester tester, String name) async {
  late OpenWallet wallet;
  await tester.runAsync(() async {
    final seed = await generateSeed(format: SeedFormat.polyseed);
    wallet = await createWalletFromSeed(
      name: name,
      network: Network.testnet,
      mode: SyncMode.lws,
      words: seed.words.join(' '),
      password: _password,
      createdHere: true,
    );
    wallet.lock();
  });
  return wallet;
}

Future<void> _open(WidgetTester tester, String name) async {
  await tester.tap(find.text('Testnet'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(name));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField), _password);
  await tester.tap(find.widgetWithText(FilledButton, 'Unlock'));
  await pumpUntilFound(tester, find.text('Balance'));
}

void main() {
  setUpAll(initRustForTests);

  testWidgets('no server set: the wallet asks for one and shares nothing', (
    tester,
  ) async {
    useDesktopWindow(tester);
    await tester.runAsync(() => clearLwsServer(network: Network.testnet));
    await _lwsWallet(tester, 'No server');
    await tester.pumpWidget(await testApp(tester));
    await _open(tester, 'No server');

    await pumpUntilFound(
      tester,
      find.text(
        'Set a light wallet server for this network to sync this wallet.',
      ),
    );
    expect(find.text('Set a server'), findsOneWidget);
  });

  testWidgets('consent: cancel shares nothing, accept is per server', (
    tester,
  ) async {
    useDesktopWindow(tester);
    // A server that does not answer, so nothing leaves the test even after
    // consent.
    await tester.runAsync(
      () => setLwsServer(network: Network.testnet, url: 'http://127.0.0.1:2'),
    );
    await _lwsWallet(tester, 'Consent');
    await tester.pumpWidget(await testApp(tester));
    await _open(tester, 'Consent');

    await pumpUntilFound(
      tester,
      find.textContaining('will share its private view key with 127.0.0.1'),
    );
    await tester.tap(find.text('Review and connect'));
    await pumpUntilFound(tester, find.text('Share your view key?'));
    expect(find.text('http://127.0.0.1:2'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Review and connect'), findsOneWidget);

    await tester.tap(find.text('Review and connect'));
    await pumpUntilFound(tester, find.text('Share your view key?'));
    await tester.tap(find.widgetWithText(FilledButton, 'Share and connect'));
    await pumpUntilFound(
      tester,
      find.text('The node is not answering. Retrying in 30 seconds.'),
    );

    // A different server needs consent again.
    await tester.runAsync(
      () => setLwsServer(network: Network.testnet, url: 'http://127.0.0.1:3'),
    );
    await tester.tap(find.byTooltip('Wallet options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lock'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), _password);
    await tester.tap(find.widgetWithText(FilledButton, 'Unlock'));
    await pumpUntilFound(
      tester,
      find.textContaining('will share its private view key with 127.0.0.1'),
    );
  });

  testWidgets('switching a full-sync wallet to a light wallet server', (
    tester,
  ) async {
    useDesktopWindow(tester);
    await tester.runAsync(() async {
      await clearLwsServer(network: Network.testnet);
      final seed = await generateSeed(format: SeedFormat.polyseed);
      (await createWalletFromSeed(
        name: 'Switcher',
        network: Network.testnet,
        mode: SyncMode.full,
        words: seed.words.join(' '),
        password: _password,
        createdHere: true,
      )).lock();
    });
    await tester.pumpWidget(await testApp(tester));
    await _open(tester, 'Switcher');

    await tester.tap(find.byTooltip('Wallet options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Switch to light wallet server'));
    await tester.pumpAndSettle();
    expect(find.text('Switch sync mode?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Switch'));
    await pumpUntilFound(
      tester,
      find.text(
        'Set a light wallet server for this network to sync this wallet.',
      ),
    );
    expect(find.text('Light wallet server'), findsWidgets);
  });
}
