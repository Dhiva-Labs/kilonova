import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kilonova/features/settings/price_feed.dart';
import 'package:kilonova/features/wallets/wallet_registry.dart';
import 'package:kilonova/src/rust/api/cold.dart';
import 'package:kilonova/src/rust/api/preferences.dart';
import 'package:kilonova/src/rust/api/requests.dart';
import 'package:kilonova/src/rust/api/send.dart';
import 'package:kilonova/src/rust/api/sync.dart';
import 'package:kilonova/src/rust/api/network.dart';
import 'package:kilonova/src/rust/api/nodes.dart';
import 'package:kilonova/src/rust/api/wallets.dart';

import 'package:kilonova/widgets/password_fields.dart';

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
      // History is a lazy list: tall enough that all 12 rows are built.
      tester.view.physicalSize = const Size(1280, 2200);
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
        find.textContaining('Synced, block'),
        timeout: const Duration(seconds: 60),
      );

      expect(find.textContaining('Mined'), findsNWidgets(12));
      // Mined outputs stay locked for 60 blocks, so nothing is spendable.
      expect(find.textContaining('spendable'), findsOneWidget);
      expect(find.text('0.0 XMR'), findsNothing);
    },
    skip: Platform.environment['KN_REGTEST'] != '1',
  );

  testWidgets(
    'an LWS-mode wallet syncs through monero-lws after consent',
    (tester) async {
      useDesktopWindow(tester);
      // History is a lazy list: tall enough that all 12 rows are built.
      tester.view.physicalSize = const Size(1280, 2200);
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
      await pumpUntilFound(tester, find.textContaining('Synced, block'));
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

  testWidgets(
    'sends from the app and sees the spend confirmed',
    (tester) async {
      useDesktopWindow(tester);
      late String payee;
      late String burn;
      await tester.runAsync(() async {
        await selectNode(network: Network.mainnet, url: _node);
        Future<OpenWallet> make(String name) async {
          final seed = await generateSeed(format: SeedFormat.classic);
          return createWalletFromSeed(
            name: name,
            network: Network.mainnet,
            mode: SyncMode.full,
            words: seed.words.join(' '),
            password: 'regtest password',
            restoreHeight: BigInt.zero,
            createdHere: true,
          );
        }

        final sender = await make('Sender');
        final payeeWallet = await make('Payee');
        payee = payeeWallet.addresses().first.address;
        burn = (await make('Burn')).addresses().first.address;
        // Mined outputs unlock after 60 blocks.
        await _mine(sender.addresses().first.address, 70);
        sender.lock();
        payeeWallet.lock();
      });

      await tester.pumpWidget(await testApp(tester));
      await tester.tap(find.text('Sender'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'regtest password');
      await tester.tap(find.widgetWithText(FilledButton, 'Unlock'));
      await pumpUntilFound(
        tester,
        find.textContaining('Synced, block'),
        timeout: const Duration(seconds: 90),
      );

      await tester.tap(find.widgetWithText(FilledButton, 'Send'));
      await tester.pumpAndSettle();
      await tester.enterText(fieldWithLabel('To'), payee);
      await tester.enterText(fieldWithLabel('Amount'), '1.5');
      await tester.tap(find.text('Review'));
      await pumpUntilFound(
        tester,
        find.text('Check before sending'),
        timeout: const Duration(seconds: 60),
      );
      expect(find.text('1.5 XMR'), findsOneWidget);
      expect(
        find.textContaining('Published through 127.0.0.1'),
        findsOneWidget,
      );

      // A wrong password publishes nothing and keeps the transaction.
      await tester.enterText(find.byType(TextField), 'not it');
      await tester.tap(find.text('Send now'));
      await pumpUntilFound(
        tester,
        find.text('That password does not open this wallet.'),
      );
      await tester.enterText(find.byType(TextField), 'regtest password');
      await tester.tap(find.text('Send now'));
      await pumpUntilFound(
        tester,
        find.text('Sent. It confirms when the next block is mined.'),
        timeout: const Duration(seconds: 30),
      );
      await pumpUntilFound(tester, find.textContaining('Pending'));

      await tester.runAsync(() => _mine(burn, 1));
      await pumpUntil(
        tester,
        () => find.textContaining('Pending').evaluate().isEmpty,
        what: 'the spend to be confirmed',
        timeout: const Duration(seconds: 90),
      );
      expect(find.textContaining('To '), findsWidgets);

      // The sent transaction remembers who was paid and its key.
      await tester.tap(find.textContaining('To ').first);
      await tester.pumpAndSettle();
      // Eyebrow labels render upper case.
      expect(find.text('PAID TO'), findsOneWidget);
      expect(find.text(payee), findsOneWidget);
      await tester.enterText(
        fieldWithLabel('Note, only on this device'),
        'test payment',
      );
      await tester.pump();
      await tester.ensureVisible(find.text('Save note'));
      await tester.tap(find.text('Save note'));
      await tester.pumpAndSettle();
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
      await pumpUntil(
        tester,
        () => find
            .byWidgetPredicate(
              (w) =>
                  w is SelectableText &&
                  RegExp(r'^[0-9a-f]{64,}$').hasMatch(w.data ?? ''),
            )
            .evaluate()
            .isNotEmpty,
        what: 'the transaction key',
      );
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('test payment'), findsOneWidget);
    },
    skip: Platform.environment['KN_REGTEST'] != '1',
  );

  testWidgets(
    'a payment arriving while the app is away is announced',
    (tester) async {
      final notifier = FakeNotifier();
      final registry = WalletRegistry(
        notifier: notifier,
        price: PriceFeed(fetch: () async => null),
      );
      late OpenWallet sender;
      late OpenWallet payee;
      await tester.runAsync(() async {
        await selectNode(network: Network.mainnet, url: _node);
        await setPreferences(
          preferences: const Preferences(
            notifyIncoming: true,
            backgroundSync: false,
            confirmLwsPayments: false,
          ),
        );
        await registry.reload();
        Future<OpenWallet> make(String name) async {
          final seed = await generateSeed(format: SeedFormat.classic);
          return createWalletFromSeed(
            name: name,
            network: Network.mainnet,
            mode: SyncMode.full,
            words: seed.words.join(' '),
            password: 'regtest password',
            restoreHeight: BigInt.zero,
            createdHere: true,
          );
        }

        sender = await make('Away sender');
        payee = await make('Away payee');
        await _mine(sender.addresses().first.address, 70);
        await registry.opened(sender);
        await registry.opened(payee);
      });
      bool synced(OpenWallet w) =>
          registry.syncOf(w.summary().id).value?.phase == SyncPhase.synced;
      await pumpUntil(
        tester,
        () => synced(sender) && synced(payee),
        what: 'both wallets to sync',
        timeout: const Duration(seconds: 120),
      );

      registry.foreground = false;
      // Sync pace is process-wide; later tests expect the foreground pace.
      addTearDown(() => registry.foreground = true);
      await tester.runAsync(() async {
        final send = await sender.prepareSend(
          payments: [
            Payment(
              address: payee.addresses().first.address,
              amount: BigInt.from(250000000000),
            ),
          ],
          priority: FeePriority.normal,
        );
        await sender.confirmSend(send: send, password: 'regtest password');
        registry.startSync(payee.summary().id);
      });
      await pumpUntil(
        tester,
        () => notifier.payments.isNotEmpty,
        what: 'a payment notification',
        timeout: const Duration(seconds: 90),
      );
      expect(notifier.payments.single, (
        'Payment received in Away payee',
        '+0.25 XMR, waiting for a block',
      ));
      registry.lockAll();
      await tester.runAsync(
        () => setPreferences(
          preferences: const Preferences(
            notifyIncoming: false,
            backgroundSync: false,
            confirmLwsPayments: false,
          ),
        ),
      );
    },
    skip: Platform.environment['KN_REGTEST'] != '1',
  );

  testWidgets('a cold wallet pairs, syncs key images, and signs a send for its '
      'watching wallet', (tester) async {
    useDesktopWindow(tester);
    final cold = FakeColdTransport();
    final registry = WalletRegistry(
      cold: cold,
      price: PriceFeed(fetch: () async => null),
    );
    late String aId;
    late String payee;
    await tester.runAsync(() async {
      await selectNode(network: Network.mainnet, url: _node);
      final seed = await generateSeed(format: SeedFormat.classic);
      final a = await createWalletFromSeed(
        name: 'Cold owner',
        network: Network.mainnet,
        mode: SyncMode.full,
        words: seed.words.join(' '),
        password: 'regtest password',
        restoreHeight: BigInt.zero,
        createdHere: true,
      );
      aId = a.summary().id;
      payee = (await createWalletFromSeed(
        name: 'Payee',
        network: Network.mainnet,
        mode: SyncMode.full,
        words: (await generateSeed(format: SeedFormat.classic)).words.join(' '),
        password: 'regtest password',
        restoreHeight: BigInt.zero,
        createdHere: true,
      )).addresses().first.address;
      // Mined outputs unlock after 60 blocks.
      await _mine(a.addresses().first.address, 70);
      a.lock();
    });

    await tester.pumpWidget(await testAppWithRegistry(tester, registry));
    await tester.tap(find.text('Cold owner'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'regtest password');
    await tester.tap(find.widgetWithText(FilledButton, 'Unlock'));
    await pumpUntilFound(
      tester,
      find.textContaining('Synced, block'),
      timeout: const Duration(seconds: 90),
    );

    // Turn the owner's wallet into an offline, signing-only wallet.
    await tester.tap(find.byTooltip('Wallet options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use as offline wallet'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(FilledButton, 'Use as offline wallet'),
    );
    await pumpUntilFound(tester, find.text('Offline wallet'));

    // Pair a watching wallet from it.
    await tester.tap(find.text('Pair a watching wallet'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'regtest password');
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    await pumpUntilFound(
      tester,
      find.text('Show this to your watching wallet'),
    );
    final pairing = cold.shownMessages.last;
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    cold.toReceive.add(pairing.file);
    await openAddWallet(tester);
    await tester.tap(find.text('Pair with an offline wallet'));
    await tester.pumpAndSettle();
    await tester.enterText(fieldWithLabel('Wallet name'), 'Watching');
    await tester.enterText(fieldWithLabel('Password'), 'watcher password');
    await tester.enterText(
      fieldWithLabel('Confirm password'),
      'watcher password',
    );
    await tester.tap(find.text('Create watching wallet'));
    await pumpUntilFound(
      tester,
      find.text('Sync with offline wallet'),
      timeout: const Duration(seconds: 90),
    );

    // Learn key images for the coins the watching wallet can see but not
    // yet derive key images for, by relaying through the cold wallet's
    // own API (standing in for its UI, which is covered elsewhere).
    await tester.tap(find.text('Sync with offline wallet'));
    await pumpUntilFound(tester, find.text('Show this to your offline wallet'));
    final syncRequest = cold.shownMessages.last;
    late ColdMessage syncAnswer;
    await tester.runAsync(() async {
      final a = registry.openWallet(aId)!;
      final request = await a.readColdRequest(message: syncRequest.file);
      syncAnswer = await a.answerColdRequest(request: request, password: '');
    });
    cold.toReceive.add(syncAnswer.file);
    await tester.tap(find.text('Scan the answer'));
    await pumpUntilFound(
      tester,
      find.textContaining('Learned key images'),
      timeout: const Duration(seconds: 90),
    );
    await tester.pumpAndSettle();
    await pumpUntilFound(
      tester,
      find.textContaining('Synced, block'),
      timeout: const Duration(seconds: 90),
    );

    // Send from the watching wallet; the cold wallet signs it.
    await tester.tap(find.widgetWithText(FilledButton, 'Send'));
    await tester.pumpAndSettle();
    await tester.enterText(fieldWithLabel('To'), payee);
    await tester.enterText(fieldWithLabel('Amount'), '1.5');
    await tester.tap(find.text('Review'));
    await pumpUntilFound(
      tester,
      find.text('Sign this on your offline wallet'),
      timeout: const Duration(seconds: 60),
    );
    final signRequest = cold.shownMessages.last;
    late ColdMessage signed;
    await tester.runAsync(() async {
      final a = registry.openWallet(aId)!;
      final request = await a.readColdRequest(message: signRequest.file);
      signed = await a.answerColdRequest(
        request: request,
        password: 'regtest password',
      );
    });
    cold.toReceive.add(signed.file);
    await tester.drag(find.byType(ListView).last, const Offset(0, -600));
    await tester.pumpAndSettle();
    await pumpUntilFound(tester, find.text('Scan the signed transaction'));
    await tester.tap(find.text('Scan the signed transaction'));
    await pumpUntilFound(
      tester,
      find.text('Sent. It confirms when the next block is mined.'),
      timeout: const Duration(seconds: 30),
    );

    final watching = registry.find(
      registry.on(Network.mainnet).firstWhere((w) => w.name == 'Watching').id,
    )!;
    final b = registry.openWallet(watching.id)!;
    expect(
      b.history().any((h) => !h.incoming),
      isTrue,
      reason: 'the watching wallet should show the send it just signed',
    );

    await tester.runAsync(() => _mine(payee, 1));
    await pumpUntil(
      tester,
      () => b.history().any((h) => !h.incoming && !h.pending),
      what: 'the signed send to confirm',
      timeout: const Duration(seconds: 90),
    );
  }, skip: Platform.environment['KN_REGTEST'] != '1');

  testWidgets(
    'a payment request is marked paid once its payment confirms',
    (tester) async {
      final registry = WalletRegistry(
        price: PriceFeed(fetch: () async => null),
      );
      late OpenWallet payer;
      late OpenWallet receiver;
      late RequestRow request;
      await tester.runAsync(() async {
        await selectNode(network: Network.mainnet, url: _node);
        Future<OpenWallet> make(String name) async {
          final seed = await generateSeed(format: SeedFormat.classic);
          return createWalletFromSeed(
            name: name,
            network: Network.mainnet,
            mode: SyncMode.full,
            words: seed.words.join(' '),
            password: 'regtest password',
            restoreHeight: BigInt.zero,
            createdHere: true,
          );
        }

        payer = await make('Request payer');
        receiver = await make('Request receiver');
        await _mine(payer.addresses().first.address, 70);
        request = await receiver.createRequest(
          amount: BigInt.from(250000000000),
          label: 'Coffee',
        );
        await registry.opened(payer);
        await registry.opened(receiver);
      });
      bool synced(OpenWallet w) =>
          registry.syncOf(w.summary().id).value?.phase == SyncPhase.synced;
      await pumpUntil(
        tester,
        () => synced(payer) && synced(receiver),
        what: 'both wallets to sync',
        timeout: const Duration(seconds: 120),
      );

      await tester.runAsync(() async {
        final send = await payer.prepareSend(
          payments: [Payment(address: request.address, amount: request.amount)],
          priority: FeePriority.normal,
        );
        await payer.confirmSend(send: send, password: 'regtest password');
        registry.startSync(payer.summary().id);
      });
      await pumpUntil(
        tester,
        () => receiver.requests().first.status == RequestStatus.arriving,
        what: 'the request to show the payment arriving',
        timeout: const Duration(seconds: 90),
      );

      await tester.runAsync(() => _mine(payer.addresses().first.address, 1));
      await pumpUntil(
        tester,
        () => receiver.requests().first.status == RequestStatus.paid,
        what: 'the request to be marked paid',
        timeout: const Duration(seconds: 90),
      );
      registry.lockAll();
    },
    skip: Platform.environment['KN_REGTEST'] != '1',
  );
}
