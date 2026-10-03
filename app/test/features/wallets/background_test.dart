import 'package:flutter_test/flutter_test.dart';
import 'package:kilonova/features/settings/price_feed.dart';
import 'package:kilonova/features/wallets/wallet_registry.dart';
import 'package:kilonova/src/rust/api/network.dart';
import 'package:kilonova/src/rust/api/preferences.dart';
import 'package:kilonova/src/rust/api/wallets.dart';

import '../../helpers/rust.dart';

Future<OpenWallet> _wallet(String name) async {
  final seed = await generateSeed(format: SeedFormat.classic);
  return createWalletFromSeed(
    name: name,
    network: Network.mainnet,
    mode: SyncMode.full,
    words: seed.words.join(' '),
    password: 'pw',
    createdHere: true,
  );
}

void main() {
  setUpAll(initRustForTests);

  test('leaving the app locks wallets unless background sync is on', () async {
    final notifier = FakeNotifier();
    final registry = WalletRegistry(
      notifier: notifier,
      price: PriceFeed(fetch: () async => null),
    );
    await registry.reload();
    expect(registry.preferences.backgroundSync, isFalse);

    final first = await _wallet('Away');
    await registry.opened(first);
    final id = first.summary().id;
    registry.paused();
    expect(registry.openWallet(id), isNull, reason: 'locked by default');
    expect(notifier.keptAlive, isFalse);
    registry.resumed();

    await setPreferences(
      preferences: const Preferences(
        notifyIncoming: true,
        backgroundSync: true,
        confirmLwsPayments: false,
      ),
    );
    await registry.reload();
    final second = await _wallet('Kept');
    await registry.opened(second);
    registry.paused();
    expect(registry.openWallet(second.summary().id), isNotNull);
    expect(notifier.keptAlive, isTrue);
    expect(registry.foreground, isFalse);
    registry.resumed();
    expect(notifier.keptAlive, isFalse);
    expect(registry.foreground, isTrue);

    // Where background sync is impossible, the setting does not apply.
    final desktop = WalletRegistry(
      notifier: FakeNotifier(supportsBackgroundSync: false),
      price: PriceFeed(fetch: () async => null),
    );
    await desktop.reload();
    final third = await _wallet('Desktop');
    final thirdId = third.summary().id;
    await desktop.opened(third);
    desktop.paused();
    expect(desktop.openWallet(thirdId), isNull);
    registry.lockAll();
    desktop.lockAll();
    await setPreferences(
      preferences: const Preferences(
        notifyIncoming: false,
        backgroundSync: false,
        confirmLwsPayments: false,
      ),
    );
  });
}
