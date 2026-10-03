import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kilonova/features/settings/price_feed.dart';
import 'package:kilonova/features/settings/push_screen.dart';
import 'package:kilonova/features/wallets/wallet_registry.dart';
import 'package:kilonova/l10n/generated/app_localizations.dart';
import 'package:kilonova/platform/push.dart';
import 'package:kilonova/src/rust/api/network.dart';
import 'package:kilonova/src/rust/api/nodes.dart';
import 'package:kilonova/src/rust/api/push.dart';
import 'package:kilonova/src/rust/api/wallets.dart';
import 'package:kilonova/theme/theme.dart';

import '../../helpers/rust.dart';

const _onion = 'ciczdlujjvdfuvwndzmqpefmndzxelyh3cbip4eqwet6it3tmuwgh2ad.onion';
const _topic = 'kn08da05109b5030ab437d84150b2eccfb';

/// Records subscriptions instead of reaching a distributor or a server.
class FakePush extends PushChannel {
  FakePush({this.notifiesItself = false});

  @override
  final bool notifiesItself;

  final subscribed = <String, PushSubscription>{};
  final titles = <String>[];
  final _states = ValueNotifier<Map<String, PushState>>(const {});

  @override
  bool get supported => true;

  @override
  ValueListenable<Map<String, PushState>> get states => _states;

  @override
  Future<void> start(void Function(String walletId) onArrived) async {}

  @override
  Future<PushState> subscribe(
    PushSubscription subscription, {
    required String title,
    required String body,
  }) async {
    subscribed[subscription.walletId] = subscription;
    titles.add(title);
    _states.value = {
      ..._states.value,
      subscription.walletId: PushState.waiting,
    };
    return PushState.waiting;
  }

  @override
  Future<void> unsubscribe(String walletId) async {
    subscribed.remove(walletId);
    _states.value = Map.of(_states.value)..remove(walletId);
  }

  @override
  void dispose() => _states.dispose();
}

Future<OpenWallet> _wallet(String name, {SyncMode mode = SyncMode.full}) async {
  final seed = await generateSeed(format: SeedFormat.classic);
  return createWalletFromSeed(
    name: name,
    network: Network.stagenet,
    mode: mode,
    words: seed.words.join(' '),
    password: 'pw',
    createdHere: true,
  );
}

void main() {
  setUpAll(initRustForTests);

  test('desktops poll each topic and report pushes once', () async {
    final polls = <(String, String)>[];
    var arrive = 0;
    final push = DesktopPush(
      interval: const Duration(hours: 1),
      subscriptions: () async => [
        const PushSubscription(
          walletId: 'w1',
          server: 'http://a',
          topic: _topic,
        ),
      ],
      poll: (id, since) async {
        polls.add((id, since));
        return PushPoll(arrived: arrive, since: arrive > 0 ? 'abc' : since);
      },
    );
    final arrived = <String>[];
    await push.start(arrived.add);
    expect(arrived, isEmpty);
    expect(push.states.value['w1'], PushState.ready);

    arrive = 2;
    await push.pollNow();
    expect(arrived, ['w1']);
    arrive = 0;
    await push.pollNow();
    expect(arrived, ['w1']);
    expect(polls.last, ('w1', 'abc'), reason: 'continues after the last');
    push.dispose();
  });

  test('a push notifies without an amount, only when it has to', () async {
    final notifier = FakeNotifier();
    final push = FakePush();
    final registry = WalletRegistry(
      notifier: notifier,
      push: push,
      price: PriceFeed(fetch: () async => null),
    );
    final wallet = await _wallet('Savings');
    final id = wallet.summary().id;
    wallet.lock();
    await registry.reload();

    registry.pushArrived(id);
    expect(notifier.payments, isEmpty, reason: 'the app is on screen');

    registry.foreground = false;
    registry.pushArrived(id);
    expect(notifier.payments, [
      ('Something arrived for Savings', 'Open Kilonova to see it.'),
    ]);

    registry.pushArrived('no such wallet');
    expect(notifier.payments, hasLength(1));

    // Android shows its own notification.
    final android = WalletRegistry(
      notifier: notifier,
      push: FakePush(notifiesItself: true),
      price: PriceFeed(fetch: () async => null),
    );
    await android.reload();
    android.foreground = false;
    android.pushArrived(id);
    expect(notifier.payments, hasLength(1));
  });

  testWidgets('a code without a server uses the paired one', (tester) async {
    final push = FakePush();
    final registry = WalletRegistry(
      notifier: FakeNotifier(),
      push: push,
      price: PriceFeed(fetch: () async => null),
    );
    final wallet = (await tester.runAsync(
      () => _wallet('Phone', mode: SyncMode.lws),
    ))!;
    final summary = wallet.summary();
    wallet.lock();
    await tester.runAsync(
      () => pairWithServer(
        code:
            'kilonova-server:?network=stagenet'
            '&lws=http%3A%2F%2F$_onion%3A8443&push=http%3A%2F%2F$_onion',
      ),
    );
    await tester.runAsync(registry.reload);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: PushScreen(registry: registry),
      ),
    );
    await pumpUntilFound(tester, find.text('Phone'));
    await tester.tap(find.text('Phone'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'not a code');
    await tester.tap(find.text('Turn on'));
    await pumpUntilFound(
      tester,
      find.text('This is not a code from push-register.'),
    );

    await tester.enterText(
      find.byType(TextField),
      'kilonova-push:?topic=$_topic',
    );
    await tester.tap(find.text('Turn on'));
    await pumpUntilFound(tester, find.text('Waiting for your server'));
    expect(find.text('http://$_onion'), findsOneWidget);
    expect(push.subscribed[summary.id]?.topic, _topic);
    expect(push.titles, ['Something arrived for Phone']);

    final saved = await tester.runAsync(pushSubscriptions);
    expect(saved!.single.server, 'http://$_onion');

    await tester.tap(find.text('Turn off'));
    await pumpUntilFound(tester, find.text('Scan the code'));
    expect(push.subscribed, isEmpty);
    expect(await tester.runAsync(pushSubscriptions), isEmpty);
  });
}
