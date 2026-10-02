import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kilonova/src/rust/api/network.dart';
import 'package:kilonova/src/rust/api/nodes.dart';
import 'package:kilonova/src/rust/api/wallets.dart';

import '../helpers/rust.dart';

/// Syncs a wallet in the app against the regtest chain from tools/devnet.
/// Runs only with the devnet up and `KN_REGTEST=1`:
///
///     cd tools/devnet && docker compose --profile regtest up -d
///     cd app && KN_REGTEST=1 flutter test test/features/sync_regtest_test.dart
const _node = 'http://127.0.0.1:18181';
const _lws = 'http://127.0.0.1:18443';

/// The plain dart:io client, unlike the one flutter_test installs.
class _RealHttp extends HttpOverrides {}

Future<void> _mine(String address, int blocks) async {
  // flutter_test fakes dart:io HTTP; this call has to reach the devnet.
  final client = HttpOverrides.runWithHttpOverrides(
    HttpClient.new,
    _RealHttp(),
  );
  try {
    final request = await client.postUrl(Uri.parse('$_node/json_rpc'));
    final payload = utf8.encode(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': '0',
        'method': 'generateblocks',
        'params': {'amount_of_blocks': blocks, 'wallet_address': address},
      }),
    );
    // monerod does not accept chunked request bodies.
    request.contentLength = payload.length;
    request.add(payload);
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    expect(body, contains('"blocks"'));
  } finally {
    client.close();
  }
}

void main() {
  setUpAll(initRustForTests);

  testWidgets(
    'mined funds show up as balance and history',
    (tester) async {
      useDesktopWindow(tester);
      await tester.runAsync(() async {
        await selectNode(network: Network.mainnet, url: _node);
        final seed = await generateSeed(format: SeedFormat.classic);
        final wallet = await createWalletFromSeed(
          name: 'Miner',
          network: Network.mainnet,
          mode: SyncMode.full,
          words: seed.words.join(' '),
          password: 'regtest password',
          // Regtest heights are small; start at the beginning.
          restoreHeight: BigInt.zero,
          createdHere: true,
        );
        await _mine(wallet.addresses().first.address, 12);
        wallet.lock();
      });

      await tester.pumpWidget(await testApp(tester));
      await tester.tap(find.text('Miner'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'regtest password');
      await tester.tap(find.widgetWithText(FilledButton, 'Unlock'));
      await pumpUntilFound(
        tester,
        find.textContaining('Up to date at block'),
        timeout: const Duration(seconds: 60),
      );

      expect(find.textContaining('Mined'), findsNWidgets(12));
      // Mined outputs stay locked for 60 blocks, so nothing is spendable.
      expect(find.textContaining('can be spent now'), findsOneWidget);
      expect(find.text('0.0 XMR'), findsNothing);
    },
    skip: Platform.environment['KN_REGTEST'] != '1',
  );

  testWidgets(
    'an LWS-mode wallet syncs through monero-lws after consent',
    (tester) async {
      useDesktopWindow(tester);
      late String address;
      await tester.runAsync(() async {
        await setLwsServer(network: Network.mainnet, url: _lws);
        final seed = await generateSeed(format: SeedFormat.polyseed);
        final wallet = await createWalletFromSeed(
          name: 'Light',
          network: Network.mainnet,
          mode: SyncMode.lws,
          words: seed.words.join(' '),
          password: 'regtest password',
          createdHere: true,
        );
        address = wallet.addresses().first.address;
        wallet.lock();
      });

      await tester.pumpWidget(await testApp(tester));
      await tester.tap(find.text('Light'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'regtest password');
      await tester.tap(find.widgetWithText(FilledButton, 'Unlock'));
      await pumpUntilFound(tester, find.text('Review and connect'));
      await tester.tap(find.text('Review and connect'));
      await pumpUntilFound(tester, find.text('Share and connect'));
      await tester.tap(find.text('Share and connect'));
      // Registered with the server; now pay it.
      await pumpUntilFound(tester, find.textContaining('Up to date at block'));
      await tester.runAsync(() => _mine(address, 12));

      await pumpUntil(
        tester,
        () => find.textContaining('Mined').evaluate().length == 12,
        what: '12 mined payments from monero-lws',
        timeout: const Duration(seconds: 90),
      );
    },
    skip: Platform.environment['KN_REGTEST'] != '1',
  );
}
