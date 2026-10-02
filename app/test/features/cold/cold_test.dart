import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kilonova/features/settings/price_feed.dart';
import 'package:kilonova/features/wallets/wallet_registry.dart';
import 'package:kilonova/src/rust/api/cold.dart';
import 'package:kilonova/src/rust/api/network.dart';
import 'package:kilonova/src/rust/api/wallets.dart';

import '../../helpers/rust.dart';

/// Builds a registry with a fake cold transport, so scans and saves are
/// recorded instead of touching the camera or filesystem.
WalletRegistry _registry(FakeColdTransport cold) => WalletRegistry(
  cold: cold,
  price: PriceFeed(fetch: () async => null),
);

Future<OpenWallet> _wallet(String name, String password) async {
  final seed = await generateSeed(format: SeedFormat.polyseed);
  return createWalletFromSeed(
    name: name,
    network: Network.mainnet,
    mode: SyncMode.full,
    words: seed.words.join(' '),
    password: password,
    restoreHeight: BigInt.zero,
    createdHere: true,
  );
}

void main() {
  setUpAll(initRustForTests);

  testWidgets('a cold wallet page shows the offline card and no Send', (
    tester,
  ) async {
    useDesktopWindow(tester);
    final cold = FakeColdTransport();
    final registry = _registry(cold);
    await tester.runAsync(() async {
      final wallet = await _wallet('Cold A', 'pw123456');
      await wallet.setCold(cold: true);
      await registry.opened(wallet);
    });

    await tester.pumpWidget(await testAppWithRegistry(tester, registry));
    await tester.tap(find.text('Cold A'));
    await tester.pumpAndSettle();

    expect(find.text('Offline wallet'), findsOneWidget);
    expect(find.text('Scan a request'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Send'), findsNothing);
  });

  testWidgets('pairing creates a matching view-only watching wallet', (
    tester,
  ) async {
    useDesktopWindow(tester);
    final cold = FakeColdTransport();
    final registry = _registry(cold);
    late String coldAddress;
    await tester.runAsync(() async {
      final wallet = await _wallet('Cold B', 'pw123456');
      coldAddress = wallet.addresses().first.address;
      await wallet.setCold(cold: true);
      await registry.opened(wallet);
    });

    await tester.pumpWidget(await testAppWithRegistry(tester, registry));
    await tester.tap(find.text('Cold B'));
    await tester.pumpAndSettle();

    // Show the pairing code; the fake records it instead of a real QR scan.
    await tester.tap(find.text('Pair a watching wallet'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'pw123456');
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    await pumpUntilFound(
      tester,
      find.text('Show this to your watching wallet'),
    );
    expect(cold.shownMessages, isNotEmpty);
    final pairing = cold.shownMessages.last;
    expect(pairing.kind, ColdKind.pairing);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    // The watching side scans that file and creates its wallet.
    cold.toReceive.add(pairing.file);
    await openAddWallet(tester);
    await tester.tap(find.text('Pair with an offline wallet'));
    await tester.pumpAndSettle();

    await tester.enterText(fieldWithLabel('Wallet name'), 'Watching B');
    await tester.enterText(fieldWithLabel('Password'), 'watchpw12');
    await tester.enterText(fieldWithLabel('Confirm password'), 'watchpw12');
    await tester.tap(find.text('Create watching wallet'));
    await pumpUntilFound(tester, find.textContaining('View-only'));
    final watching = registry
        .on(Network.mainnet)
        .firstWhere((w) => w.name == 'Watching B');
    expect(
      registry.openWallet(watching.id)!.addresses().first.address,
      coldAddress,
    );
  });

  testWidgets('a sync request is answered by the cold wallet', (tester) async {
    useDesktopWindow(tester);
    final cold = FakeColdTransport();
    final registry = _registry(cold);
    late ColdMessage request;
    await tester.runAsync(() async {
      final coldWallet = await _wallet('Cold C', 'pw123456');
      await coldWallet.setCold(cold: true);
      await registry.opened(coldWallet);

      final pairing = await coldWallet.coldPairing(password: 'pw123456');
      final watching = await createWatchingWallet(
        name: 'Watching C',
        message: pairing.file,
        password: 'watchpw12',
        mode: SyncMode.full,
      );
      request = await watching.coldSyncRequest();
      watching.lock();
    });

    await tester.pumpWidget(await testAppWithRegistry(tester, registry));
    await tester.tap(find.text('Cold C'));
    await tester.pumpAndSettle();

    cold.toReceive.add(request.file);
    await tester.tap(find.text('Scan a request'));
    await tester.pumpAndSettle();

    await pumpUntilFound(
      tester,
      find.text('Show this to your watching wallet'),
    );
  });
}
