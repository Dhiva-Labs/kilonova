import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kilonova/features/settings/background_screen.dart';
import 'package:kilonova/features/settings/price_feed.dart';
import 'package:kilonova/features/wallets/wallet_registry.dart';
import 'package:kilonova/l10n/generated/app_localizations.dart';
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
    restoreHeight: BigInt.from(100),
    createdHere: true,
  );
}

Future<void> _checksOff() => setPreferences(
  preferences: const Preferences(
    notifyIncoming: false,
    backgroundSync: false,
    confirmLwsPayments: false,
    broadcastElsewhere: true,
  ),
);

WalletRegistry _registry(FakeNotifier notifier, FakeBackgroundChecks checks) =>
    WalletRegistry(
      notifier: notifier,
      background: checks,
      price: PriceFeed(fetch: () async => null),
    );

Future<void> _openScreen(WidgetTester tester, WalletRegistry registry) async {
  tester.view.physicalSize = const Size(412, 915);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: BackgroundScreen(registry: registry, desktop: false),
    ),
  );
  await pumpUntilFound(
    tester,
    find.text('Off. Kilonova looks for payments only while it is open.'),
  );
}

Finder _switchIn(String title) => find.descendant(
  of: find.ancestor(of: find.text(title), matching: find.byType(Row)).first,
  matching: find.byType(Switch),
);

const _label = 'Check for payments when Kilonova is closed';

void main() {
  setUpAll(initRustForTests);
  tearDown(_checksOff);

  test('leaving the app locks wallets, with or without checks', () async {
    final checks = FakeBackgroundChecks();
    final registry = _registry(FakeNotifier(), checks);
    await registry.reload();
    expect(registry.preferences.backgroundSync, isFalse, reason: 'off');

    final first = await _wallet('Away');
    final firstId = first.summary().id;
    await registry.opened(first);
    registry.paused();
    expect(registry.openWallet(firstId), isNull);
    registry.resumed();
    expect(registry.foreground, isTrue);

    await registry.setBackgroundChecks(on: true);
    final second = await _wallet('Checked');
    final secondId = second.summary().id;
    await registry.opened(second);
    registry.paused();
    expect(
      registry.openWallet(secondId),
      isNull,
      reason: 'checks need no unlocked wallet',
    );
    registry.resumed();
  });

  test('checks off after an upgrade leave no view keys behind', () async {
    final checks = FakeBackgroundChecks();
    final registry = _registry(FakeNotifier(), checks);
    final wallet = await _wallet('Upgraded');
    final id = wallet.summary().id;
    wallet.lock();
    await registry.reload();
    await registry.checkWallet(id, 'pw');
    expect(checks.states.keys, [id]);

    // The setting is off (as the upgrade leaves it): nothing is kept.
    await registry.reload();
    expect(checks.states, isEmpty);
  });

  testWidgets('checks start off and turn on only through consent', (
    tester,
  ) async {
    final notifier = FakeNotifier();
    final checks = FakeBackgroundChecks();
    final registry = _registry(notifier, checks);
    final wallet = (await tester.runAsync(() => _wallet('Savings')))!;
    final id = wallet.summary().id;
    wallet.lock();
    await tester.runAsync(registry.reload);
    await _openScreen(tester, registry);

    final toggle = tester.widget<Switch>(_switchIn(_label));
    expect(toggle.value, isFalse, reason: 'off by default');

    await tester.tap(_switchIn(_label));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('view key is kept on this phone'),
      findsOneWidget,
    );
    expect(
      find.textContaining('never leave the password-protected'),
      findsOneWidget,
    );
    expect(notifier.permissionRequests, 0, reason: 'nothing asked yet');

    await tester.tap(find.text('Continue'));
    await pumpUntilFound(tester, find.text('Savings'));
    expect(notifier.permissionRequests, 1);

    // Choosing a wallet asks for its password; a wrong one keeps it out.
    await tester.tap(_switchIn('Savings'));
    await tester.pumpAndSettle();
    expect(find.text('Check Savings'), findsOneWidget);
    await tester.enterText(fieldWithLabel('Password'), 'wrong');
    await tester.tap(find.text('Continue'));
    await pumpUntilFound(
      tester,
      find.text('That password does not open this wallet.'),
    );
    expect(checks.states, isEmpty);
    await tester.enterText(fieldWithLabel('Password'), 'pw');
    await tester.tap(find.text('Continue'));
    await pumpUntil(tester, () => checks.states.containsKey(id));
    await tester.pumpAndSettle();

    // What is kept is view-only.
    final kept = jsonDecode(utf8.decode(checks.states[id]!)) as Map;
    expect(kept['wallet'], id);
    expect(kept.containsKey('view_key'), isTrue);
    expect(kept.keys.where((k) => '$k'.contains('spend_key')), isEmpty);
    expect(checks.labelled[id]?.title, 'Payment received in Savings');

    await tester.ensureVisible(find.text('Open battery settings'));
    await tester.tap(find.text('Open battery settings'));
    expect(checks.batterySettingsOpened, 1);

    await tester.ensureVisible(find.text('Turn on'));
    await tester.tap(find.text('Turn on'));
    await pumpUntil(tester, () => registry.preferences.backgroundSync);
    await pumpUntilFound(tester, find.text('On for 1 wallet'));
    final saved = await tester.runAsync(preferences);
    expect(saved!.backgroundSync, isTrue);

    // Turning it off deletes every kept view key.
    await tester.tap(_switchIn(_label));
    await pumpUntil(tester, () => !registry.preferences.backgroundSync);
    expect(checks.states, isEmpty);
    await pumpUntilFound(
      tester,
      find.text('Off. Kilonova looks for payments only while it is open.'),
    );
    expect((await tester.runAsync(preferences))!.backgroundSync, isFalse);
  });

  testWidgets('declining notifications keeps checks off', (tester) async {
    final notifier = FakeNotifier(allowed: false);
    final checks = FakeBackgroundChecks();
    final registry = _registry(notifier, checks);
    await tester.runAsync(registry.reload);
    await _openScreen(tester, registry);

    await tester.tap(_switchIn(_label));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await pumpUntilFound(
      tester,
      find.textContaining('Kilonova needs to show notifications'),
    );
    expect(find.text('Turn on'), findsNothing);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(_switchIn(_label)).value, isFalse);
    expect(registry.preferences.backgroundSync, isFalse);
    expect(checks.states, isEmpty);
  });

  testWidgets('leaving consent before turning on keeps nothing', (
    tester,
  ) async {
    final checks = FakeBackgroundChecks();
    final registry = _registry(FakeNotifier(), checks);
    final wallet = (await tester.runAsync(() => _wallet('Spare')))!;
    wallet.lock();
    await tester.runAsync(registry.reload);
    await _openScreen(tester, registry);

    await tester.tap(_switchIn(_label));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await pumpUntilFound(tester, find.text('Spare'));
    await tester.tap(_switchIn('Spare'));
    await tester.pumpAndSettle();
    await tester.enterText(fieldWithLabel('Password'), 'pw');
    await tester.tap(find.text('Continue'));
    await pumpUntil(tester, () => checks.states.isNotEmpty);
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Cancel'));
    await tester.tap(find.text('Cancel'));
    await pumpUntil(tester, () => checks.states.isEmpty);
    expect(registry.preferences.backgroundSync, isFalse);
  });

  test('deleting a checked wallet deletes its watch state', () async {
    final checks = FakeBackgroundChecks();
    final registry = _registry(FakeNotifier(), checks);
    final keep = await _wallet('Kept');
    final gone = await _wallet('Gone');
    final keepId = keep.summary().id;
    final goneId = gone.summary().id;
    keep.lock();
    gone.lock();
    await registry.reload();
    await registry.setBackgroundChecks(on: true);
    await registry.checkWallet(keepId, 'pw');
    await registry.checkWallet(goneId, 'pw');
    expect(checks.states.keys, unorderedEquals([keepId, goneId]));

    await deleteWallet(id: goneId, password: 'pw');
    await registry.removed(goneId);
    expect(checks.states.keys, [keepId]);
    expect(registry.preferences.backgroundSync, isTrue);

    // The last one removed: checks are off.
    await registry.stopCheckingWallet(keepId);
    expect(checks.states, isEmpty);
    expect(registry.preferences.backgroundSync, isFalse);
  });
}
