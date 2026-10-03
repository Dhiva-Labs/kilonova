import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kilonova/features/settings/background_screen.dart';
import 'package:kilonova/features/settings/price_feed.dart';
import 'package:kilonova/features/wallets/wallet_registry.dart';
import 'package:kilonova/l10n/generated/app_localizations.dart';
import 'package:kilonova/platform/desktop_shell.dart';
import 'package:kilonova/src/rust/api/network.dart';
import 'package:kilonova/src/rust/api/preferences.dart';
import 'package:kilonova/src/rust/api/wallets.dart';
import 'package:kilonova/theme/theme.dart';

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

Future<void> _keepSyncing(bool on) => setPreferences(
  preferences: Preferences(
    notifyIncoming: on,
    backgroundSync: on,
    confirmLwsPayments: false,
    broadcastElsewhere: true,
  ),
);

/// A desktop registry, as the desktop shell sets it up.
WalletRegistry _desktopRegistry(FakeNotifier notifier) => WalletRegistry(
  notifier: notifier,
  price: PriceFeed(fetch: () async => null),
)..keepsSyncingHidden = true;

void main() {
  setUpAll(initRustForTests);
  tearDown(() => _keepSyncing(false));

  test('closing the window quits unless wallets keep syncing', () {
    expect(closeAction(keepSyncing: false, hasTray: true), CloseAction.quit);
    expect(closeAction(keepSyncing: false, hasTray: false), CloseAction.quit);
    expect(
      closeAction(keepSyncing: true, hasTray: true),
      CloseAction.hideToTray,
    );
    // Without a tray the window is minimized, never hidden with no way
    // back.
    expect(
      closeAction(keepSyncing: true, hasTray: false),
      CloseAction.minimize,
    );
  });

  test('with the setting off, closing the window locks wallets', () async {
    final registry = _desktopRegistry(
      FakeNotifier(supportsBackgroundSync: false),
    );
    await registry.reload();
    final wallet = await _wallet('Closed');
    final id = wallet.summary().id;
    await registry.opened(wallet);

    expect(registry.windowClosing(hasTray: true), CloseAction.quit);
    expect(registry.openWallet(id), isNull);
  });

  test('with the setting on, a closed window keeps wallets syncing', () async {
    await _keepSyncing(true);
    final notifier = FakeNotifier(supportsBackgroundSync: false);
    final registry = _desktopRegistry(notifier);
    await registry.reload();
    final wallet = await _wallet('Tray');
    final id = wallet.summary().id;
    await registry.opened(wallet);

    expect(registry.windowClosing(hasTray: true), CloseAction.hideToTray);
    expect(registry.openWallet(id), isNotNull);
    expect(registry.foreground, isFalse);
    // The system may also report the app as paused; that must not lock.
    registry.paused();
    expect(registry.openWallet(id), isNotNull);
    expect(notifier.keptAlive, isFalse, reason: 'no Android service here');

    registry.windowOpened();
    expect(registry.foreground, isTrue);
    expect(registry.windowClosing(hasTray: false), CloseAction.minimize);
    expect(registry.openWallet(id), isNotNull);
    expect(registry.foreground, isFalse);
    registry.lockAll();
  });

  testWidgets('the Background screen offers the setting on desktops', (
    tester,
  ) async {
    final registry = _desktopRegistry(
      FakeNotifier(supportsBackgroundSync: false),
    )..hasTray = false;
    await tester.runAsync(registry.reload);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: BackgroundScreen(registry: registry, desktop: true),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Keep syncing when the window is closed'), findsOneWidget);
    expect(
      find.textContaining('Your desktop shows no tray icons'),
      findsOneWidget,
    );
    final row = find.ancestor(
      of: find.text('Keep syncing when the window is closed'),
      matching: find.byType(Row),
    );
    await tester.tap(
      find.descendant(of: row.first, matching: find.byType(Switch)),
    );
    await pumpUntil(tester, () => registry.preferences.backgroundSync);
    final saved = await tester.runAsync(preferences);
    expect(saved!.backgroundSync, isTrue);
  });
}
