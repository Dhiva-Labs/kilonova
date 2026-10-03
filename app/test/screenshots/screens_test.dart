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
import 'package:kilonova/widgets/kn_button.dart';
import 'package:kilonova/widgets/password_fields.dart';

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
      late String sentTxHash;
      late String sentTxKey;
      await tester.runAsync(() async {
        await selectNode(network: Network.mainnet, url: _node);
        await setPriceCurrency(currency: 'usd');
        await setPreferences(
          preferences: const Preferences(
            notifyIncoming: true,
            backgroundSync: false,
            confirmLwsPayments: false,
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
        final cold = await make('Cold', Network.mainnet);
        await cold.setCold(cold: true);
        cold.lock();
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
        find.textContaining('Synced, block'),
        timeout: const Duration(seconds: 90),
      );
      await _shot(tester, '04-wallet-fresh');

      // A sent transaction, so history has both directions.
      await tester.tap(find.widgetWithText(FilledButton, 'Send'));
      await tester.pumpAndSettle();
      await _shot(tester, '05-send-empty');
      await tester.enterText(fieldWithLabel('To'), payee);
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
        () => find.textContaining('Pending').evaluate().isEmpty,
        what: 'confirmation',
        timeout: const Duration(seconds: 90),
      );
      await tester.pumpAndSettle();
      await _shot(tester, '03-wallet-desktop');

      await tester.tap(find.textContaining('To ').first);
      await tester.pumpAndSettle();
      await _shot(tester, '08-tx-details');
      sentTxHash = tester
          .widgetList<SelectableText>(find.byType(SelectableText))
          .map((w) => w.data ?? '')
          .firstWhere((d) => RegExp(r'^[0-9a-f]{64}$').hasMatch(d));
      await tester.ensureVisible(find.text('Show transaction key'));
      await tester.tap(find.text('Show transaction key'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(PasswordField), 'regtest password');
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Show transaction key'),
        ),
      );
      // Matches the same 64-hex shape as the tx hash: addresses are base58
      // and much longer, so they never satisfy this, even though they are
      // selectable text too (they get a copy button of their own now).
      bool isHexKey(String d) =>
          RegExp(r'^[0-9a-f]{64}$').hasMatch(d) && d != sentTxHash;
      await pumpUntil(
        tester,
        () => find
            .byWidgetPredicate(
              (w) => w is SelectableText && isHexKey(w.data ?? ''),
            )
            .evaluate()
            .isNotEmpty,
        what: 'the transaction key',
      );
      sentTxKey = tester
          .widgetList<SelectableText>(find.byType(SelectableText))
          .map((w) => w.data ?? '')
          .firstWhere(isHexKey);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(KnButton, 'Receive'));
      await tester.pumpAndSettle();
      await _shot(tester, '09-receive');
      await tester.tap(find.widgetWithText(FilledButton, 'Request a payment'));
      await tester.pumpAndSettle();
      await tester.enterText(fieldWithLabel('Amount'), '0.25');
      await tester.enterText(fieldWithLabel('What it is for'), 'Coffee');
      await tester.tap(find.widgetWithText(FilledButton, 'Create request'));
      await pumpUntilFound(tester, find.text('Waiting'));
      await _shot(tester, '09a-request-screen');
      await tester.pageBack();
      await tester.pumpAndSettle();
      // Dismiss the receive dialog by tapping the barrier outside it.
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      // The wallet page refreshes the requests card on sync events;
      // re-selecting it forces a rebuild without waiting for one.
      await tester.tap(find.text('Everyday').first);
      await tester.pumpAndSettle();
      await _shot(tester, '09b-requests-list');

      await tester.tap(find.byTooltip('Wallet options'));
      await tester.pumpAndSettle();
      await _shot(tester, '10-wallet-menu');

      await tester.tap(find.text('Show seed'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(PasswordField), 'regtest password');
      // The dialog's title and its submit button both say "Show seed".
      await tester.tap(
        find
            .descendant(
              of: find.byType(AlertDialog),
              matching: find.text('Show seed'),
            )
            .last,
      );
      await pumpUntilFound(tester, find.text('Copy seed'));
      await _shot(tester, '10a-seed-dialog');
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Wallet options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Show keys'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(PasswordField), 'regtest password');
      // Same shape: title and submit button both say "Show keys".
      await tester.tap(
        find
            .descendant(
              of: find.byType(AlertDialog),
              matching: find.text('Show keys'),
            )
            .last,
      );
      // Eyebrow labels render upper case, so match the warning text above
      // them instead.
      await pumpUntilFound(
        tester,
        find.text(
          'The spend key controls your funds. The view key shows every '
          'payment you receive. Never share either.',
        ),
      );
      await _shot(tester, '10b-keys-dialog');
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Wallet options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Address book'));
      await tester.pumpAndSettle();
      await _shot(tester, '11-address-book');
      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Wallet options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Coins'));
      await tester.pumpAndSettle();
      await _shot(tester, '11a-coins');
      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Wallet options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Check a payment'));
      await tester.pumpAndSettle();
      await tester.enterText(fieldWithLabel('Transaction ID'), sentTxHash);
      await tester.enterText(fieldWithLabel('Transaction key'), sentTxKey);
      await tester.enterText(fieldWithLabel('Address'), payee);
      await tester.tap(find.widgetWithText(FilledButton, 'Check'));
      await pumpUntilFound(tester, find.text('received by this address'));
      await _shot(tester, '11b-check-payment');
      await tester.pageBack();
      await tester.pumpAndSettle();

      // A wallet turned cold shows the offline card instead of Send.
      await tester.tap(find.text('Cold'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'regtest password');
      await tester.tap(find.widgetWithText(FilledButton, 'Unlock'));
      await pumpUntilFound(tester, find.text('Offline wallet'));
      await _shot(tester, '11c-wallet-cold');
      await tester.tap(find.text('Everyday').first);
      await tester.pumpAndSettle();

      // Settings and its screens.
      await tester.tap(find.text('Settings'));
      await tester.pumpAndSettle();
      await _shot(tester, '12-settings');
      for (final (title, name) in [
        ('Nodes', '13-nodes'),
        ('Proxy and Tor', '15-proxy'),
        ('Prices', '16-prices'),
        ('Notifications and background', '17-background'),
        ('Backup', '17a-backup'),
        ('Restore from backup', '17b-restore-backup'),
        ('About Kilonova', '18-about'),
        ('Privacy policy', '19-privacy'),
      ]) {
        // The list is lazy; later rows may be below the fold.
        await tester.scrollUntilVisible(find.text(title), 200);
        await tester.tap(find.text(title));
        await tester.pumpAndSettle();
        await _shot(tester, name);
        await tester.pageBack();
        await tester.pumpAndSettle();
      }

      await tester.scrollUntilVisible(find.text('Light wallet servers'), -200);
      await tester.tap(find.text('Light wallet servers'));
      await tester.pumpAndSettle();
      await _shot(tester, '14-lws');
      await pumpUntil(
        tester,
        () => tester.widget<Switch>(find.byType(Switch)).onChanged != null,
        what: 'the preference to load',
      );
      await tester.tap(find.byType(Switch));
      await pumpUntil(
        tester,
        () => tester.widget<Switch>(find.byType(Switch)).value,
        what: 'the switch to flip',
      );
      await _shot(tester, '14a-lws-confirm');
      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.tap(find.text('Pair with your server'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField),
        'kilonova-server:?network=stagenet&node=http%3A%2F%2Fexample.onion'
        '%3A18089&lws=http%3A%2F%2Fexample.onion%3A8443',
      );
      await tester.tap(find.text('Pair'));
      await pumpUntilFound(tester, find.text('Proxy and Tor'));
      await _shot(tester, '14b-pair-server');
      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.pageBack();
      await tester.pumpAndSettle();

      // Create and restore.
      await tester.tap(find.text('Add wallet'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create wallet'));
      await tester.pumpAndSettle();
      await _shot(tester, '20-create');
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add wallet'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Restore wallet'));
      await tester.pumpAndSettle();
      await _shot(tester, '21-restore');
      await tester.pageBack();
      await tester.pumpAndSettle();

      // Stagenet strip.
      await tester.tap(find.text('Mainnet'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Stagenet'));
      await tester.pumpAndSettle();
      await _shot(tester, '22-stagenet');
      await tester.tap(find.text('Stagenet'));
      await tester.pumpAndSettle();
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
