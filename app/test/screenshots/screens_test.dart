import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kilonova/features/settings/price_feed.dart';
import 'package:kilonova/src/rust/api/network.dart';
import 'package:kilonova/src/rust/api/nodes.dart';
import 'package:kilonova/src/rust/api/preferences.dart';
import 'package:kilonova/src/rust/api/price.dart';
import 'package:kilonova/src/rust/api/wallets.dart';

import '../helpers/rust.dart';

/// Renders every screen to PNG files under build/screenshots, in light and
/// dark mode, at desktop and phone width, with real fonts. For design
/// review, not for CI. Needs the regtest devnet for a wallet with history:
///
///     cd app && KN_REGTEST=1 KN_SCREENSHOTS=1 \
///       flutter test --update-goldens test/screenshots
const _node = 'http://127.0.0.1:18181';
const _out = '../../build/screenshots';

class _RealHttp extends HttpOverrides {}

Future<void> _mine(String address, int blocks) async {
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
    request.contentLength = payload.length;
    request.add(payload);
    await (await request.close()).drain<void>();
  } finally {
    client.close();
  }
}

/// Loads the bundled fonts and Material icons, which flutter_test otherwise
/// replaces with a placeholder font.
Future<void> _loadFonts() async {
  final manifest =
      jsonDecode(await rootBundle.loadString('FontManifest.json'))
          as List<dynamic>;
  for (final family in manifest.cast<Map<String, dynamic>>()) {
    final loader = FontLoader(family['family'] as String);
    for (final font in (family['fonts'] as List).cast<Map<String, dynamic>>()) {
      loader.addFont(rootBundle.load(font['asset'] as String));
    }
    await loader.load();
  }
}

Future<void> _shot(WidgetTester tester, String name) async {
  for (final (mode, brightness) in [
    ('light', Brightness.light),
    ('dark', Brightness.dark),
  ]) {
    tester.platformDispatcher.platformBrightnessTestValue = brightness;
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('$_out/$name-$mode.png'),
    );
  }
  tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
  await tester.pump();
}

void _desktop(WidgetTester tester) {
  tester.view.physicalSize = const Size(1280, 860);
  tester.view.devicePixelRatio = 1;
}

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(412, 915);
  tester.view.devicePixelRatio = 1;
}

void main() {
  final enabled =
      Platform.environment['KN_SCREENSHOTS'] == '1' &&
      Platform.environment['KN_REGTEST'] == '1';

  setUpAll(() async {
    await initRustForTests();
    await _loadFonts();
  });

  testWidgets(
    'every screen',
    (tester) async {
      _desktop(tester);
      addTearDown(tester.view.reset);
      late String payee;
      late String mainnetSender;
      await tester.runAsync(() async {
        await selectNode(network: Network.mainnet, url: _node);
        await setPriceCurrency(currency: 'usd');
        await setPreferences(
          preferences: const Preferences(
            notifyIncoming: true,
            backgroundSync: false,
          ),
        );
        Future<OpenWallet> make(String name, Network network) async {
          final seed = await generateSeed(format: SeedFormat.polyseed);
          return createWalletFromSeed(
            name: name,
            network: network,
            mode: SyncMode.full,
            words: seed.words.join(' '),
            password: 'regtest password',
            restoreHeight: BigInt.zero,
            createdHere: true,
          );
        }

        final main = await make('Everyday', Network.mainnet);
        mainnetSender = main.addresses().first.address;
        final second = await make('Savings', Network.mainnet);
        payee = second.addresses().first.address;
        (await make('Testing', Network.stagenet)).lock();
        await main.newAddress(label: 'Shop');
        await main.saveContact(name: 'Ana', address: payee);
        await _mine(mainnetSender, 75);
        second.lock();
        main.lock();
      });
      final price = PriceFeed(fetch: () async => 164.2);
      await tester.pumpWidget(await testApp(tester, price: price));
      await tester.pumpAndSettle();
      await _shot(tester, '01-wallets-desktop');

      await tester.tap(find.text('Everyday'));
      await tester.pumpAndSettle();
      await _shot(tester, '02-unlock');
      await tester.enterText(find.byType(TextField), 'regtest password');
      await tester.tap(find.widgetWithText(FilledButton, 'Unlock'));
      await pumpUntilFound(
        tester,
        find.textContaining('Up to date at block'),
        timeout: const Duration(seconds: 90),
      );

      // A sent transaction, so history has both directions.
      await tester.tap(find.widgetWithText(FilledButton, 'Send'));
      await tester.pumpAndSettle();
      await _shot(tester, '05-send-empty');
      await tester.enterText(
        fieldWithLabel('To'),
        payee,
      );
      await tester.enterText(fieldWithLabel('Amount'), '2.5');
      await tester.pump();
      await _shot(tester, '06-send-filled');
      await tester.tap(find.text('Review'));
      await pumpUntilFound(
        tester,
        find.text('Check before sending'),
        timeout: const Duration(seconds: 60),
      );
      await _shot(tester, '07-send-review');
      await tester.enterText(find.byType(TextField), 'regtest password');
      await tester.tap(find.text('Send now'));
      await pumpUntilFound(
        tester,
        find.text('Sent. It confirms when the next block is mined.'),
        timeout: const Duration(seconds: 30),
      );
      await tester.runAsync(() => _mine(payee, 1));
      await pumpUntil(
        tester,
        () => find.textContaining('Waiting for a block').evaluate().isEmpty,
        what: 'confirmation',
        timeout: const Duration(seconds: 90),
      );
      await tester.pumpAndSettle();
      await _shot(tester, '03-wallet-desktop');

      await tester.tap(find.textContaining('To ').first);
      await tester.pumpAndSettle();
      await _shot(tester, '08-tx-details');
      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('Receive'),
        300,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.pumpAndSettle();
      await _shot(tester, '04-wallet-addresses');
      await tester.tap(find.byTooltip('Show QR code').first);
      await tester.pumpAndSettle();
      await _shot(tester, '09-receive');
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.byTooltip('Wallet options'),
        -300,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Wallet options'));
      await tester.pumpAndSettle();
      await _shot(tester, '10-wallet-menu');
      await tester.tap(find.text('Address book'));
      await tester.pumpAndSettle();
      await _shot(tester, '11-address-book');
      await tester.pageBack();
      await tester.pumpAndSettle();

      // Settings and its screens.
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      await _shot(tester, '12-settings');
      for (final (title, name) in [
        ('Nodes', '13-nodes'),
        ('Light wallet servers', '14-lws'),
        ('Proxy and Tor', '15-proxy'),
        ('Prices', '16-prices'),
        ('Notifications and background', '17-background'),
        ('About Kilonova', '18-about'),
        ('Privacy policy', '19-privacy'),
      ]) {
        await tester.tap(find.text(title));
        await tester.pumpAndSettle();
        await _shot(tester, name);
        await tester.pageBack();
        await tester.pumpAndSettle();
      }
      await tester.pageBack();
      await tester.pumpAndSettle();

      // Create and restore.
      await tester.tap(find.byTooltip('Add a wallet'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create wallet'));
      await tester.pumpAndSettle();
      await _shot(tester, '20-create');
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Add a wallet'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Restore wallet'));
      await tester.pumpAndSettle();
      await _shot(tester, '21-restore');
      await tester.pageBack();
      await tester.pumpAndSettle();

      // Stagenet strip.
      await tester.tap(find.text('Stagenet'));
      await tester.pumpAndSettle();
      await _shot(tester, '22-stagenet');
      await tester.tap(find.text('Mainnet'));
      await tester.pumpAndSettle();

      // Phone width.
      _phone(tester);
      await tester.pumpAndSettle();
      await _shot(tester, '30-wallets-phone');
      await tester.tap(find.text('Everyday'));
      await tester.pumpAndSettle();
      await _shot(tester, '31-wallet-phone');
      await tester.tap(find.widgetWithText(FilledButton, 'Send'));
      await tester.pumpAndSettle();
      await _shot(tester, '32-send-phone');
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      await _shot(tester, '33-settings-phone');
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 15)),
  );
}
