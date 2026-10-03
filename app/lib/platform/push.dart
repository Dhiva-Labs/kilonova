import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:unifiedpush_android/unifiedpush_android.dart';

import '../src/rust/api/push.dart';

/// Where a wallet's payment pushes stand.
enum PushState {
  /// Turned on; nothing heard from the server or the distributor yet.
  waiting,

  /// The server is reached (desktop) or the distributor bound (Android).
  ready,

  /// Android: no UnifiedPush distributor is installed.
  noDistributor,

  /// Android: the distributor uses a server other than the wallet's own.
  wrongServer,

  /// The server or its relay could not be reached, or refused.
  unreachable,
}

/// Payment pushes from the owner's own server (see `tools/selfhost`). A
/// push says only that something arrived for a wallet; the wallet then
/// syncs to see what. Topics go to that server and nowhere else.
abstract class PushChannel {
  const PushChannel();

  /// The channel this platform supports: UnifiedPush on Android, polling
  /// the server through the proxy on desktops.
  factory PushChannel.forPlatform() {
    if (Platform.isAndroid) return AndroidPush();
    if (Platform.isLinux || Platform.isWindows) return DesktopPush();
    return const NoPush();
  }

  /// Whether pushes can be received here at all.
  bool get supported;

  /// Whether each push already shows a notification of its own (Android's
  /// native side does, since the app may not be running).
  bool get notifiesItself;

  /// Each subscribed wallet's state, by wallet id.
  ValueListenable<Map<String, PushState>> get states;

  /// Starts listening for pushes; [onArrived] gets the wallet id of each.
  Future<void> start(void Function(String walletId) onArrived);

  /// Starts receiving pushes for [subscription]'s wallet. [title] and
  /// [body] are what a push notification shows.
  Future<PushState> subscribe(
    PushSubscription subscription, {
    required String title,
    required String body,
  });

  Future<void> unsubscribe(String walletId);

  /// The wallets that are unlocked and will announce their own payments
  /// (with the amount) once a push makes them sync, so the push needs no
  /// notification of its own.
  Future<void> announcing(Set<String> walletIds) async {}

  void dispose();
}

/// Where pushes are not supported (and in tests).
class NoPush extends PushChannel {
  const NoPush();

  static final _none = ValueNotifier<Map<String, PushState>>(const {});

  @override
  bool get supported => false;

  @override
  bool get notifiesItself => false;

  @override
  ValueListenable<Map<String, PushState>> get states => _none;

  @override
  Future<void> start(void Function(String walletId) onArrived) async {}

  @override
  Future<PushState> subscribe(
    PushSubscription subscription, {
    required String title,
    required String body,
  }) async => PushState.unreachable;

  @override
  Future<void> unsubscribe(String walletId) async {}

  @override
  void dispose() {}
}

/// Shared bookkeeping of per-wallet states.
mixin _States on PushChannel {
  final _states = ValueNotifier<Map<String, PushState>>(const {});

  @override
  ValueListenable<Map<String, PushState>> get states => _states;

  void mark(String walletId, PushState? state) {
    final next = Map.of(_states.value);
    if (state == null) {
      next.remove(walletId);
    } else {
      next[walletId] = state;
    }
    _states.value = next;
  }

  @override
  void dispose() => _states.dispose();
}

/// Android: pushes arrive through the owner's UnifiedPush distributor (the
/// ntfy app, pointed at their server). The distributor hands out an
/// endpoint on that server; Kilonova asks the server's relay to repeat the
/// wallet's pushes there.
class AndroidPush extends PushChannel with _States {
  AndroidPush();

  static const _native = MethodChannel('kilonova/background');
  final _up = UnifiedPushAndroid();

  @override
  bool get supported => true;

  @override
  bool get notifiesItself => true;

  @override
  Future<void> start(void Function(String walletId) onArrived) async {
    await _up.initializeCallback(
      onNewEndpoint: (endpoint, walletId) => _bind(walletId, endpoint.url),
      onRegistrationFailed: (_, walletId) =>
          mark(walletId, PushState.unreachable),
      onUnregistered: (walletId) => mark(walletId, null),
      onMessage: (_, walletId) => onArrived(walletId),
    );
    // UnifiedPush asks apps to register again at every start.
    final subscriptions = await pushSubscriptions();
    if (subscriptions.isEmpty || await _up.getDistributor() == null) return;
    for (final s in subscriptions) {
      mark(s.walletId, PushState.waiting);
      await _up.register(s.walletId, const [], null, null);
    }
  }

  Future<void> _bind(String walletId, String endpoint) async {
    try {
      await bindPushEndpoint(walletId: walletId, endpoint: endpoint);
      mark(walletId, PushState.ready);
    } on PushError catch (e) {
      mark(
        walletId,
        e == PushError.wrongServer
            ? PushState.wrongServer
            : PushState.unreachable,
      );
    }
  }

  @override
  Future<PushState> subscribe(
    PushSubscription subscription, {
    required String title,
    required String body,
  }) async {
    final id = subscription.walletId;
    if (!await _up.tryUseCurrentOrDefaultDistributor()) {
      final found = await _up.getDistributors(const []);
      if (found.isEmpty) {
        mark(id, PushState.noDistributor);
        return PushState.noDistributor;
      }
      await _up.saveDistributor(found.first);
    }
    await _native.invokeMethod<void>('pushWallet', {
      'instance': id,
      'title': title,
      'body': body,
    });
    mark(id, PushState.waiting);
    await _up.register(id, const [], null, null);
    return PushState.waiting;
  }

  @override
  Future<void> announcing(Set<String> walletIds) => _native.invokeMethod<void>(
    'pushAnnouncing',
    {'instances': walletIds.toList()},
  );

  @override
  Future<void> unsubscribe(String walletId) async {
    mark(walletId, null);
    await _native.invokeMethod<void>('pushWalletRemoved', {
      'instance': walletId,
    });
    await _up.unregister(walletId);
  }
}

/// Linux and Windows: Kilonova asks the server for new pushes every
/// [interval] while it runs (also hidden in the tray), through the proxy.
class DesktopPush extends PushChannel with _States {
  DesktopPush({
    this.interval = const Duration(minutes: 1),
    Future<PushPoll> Function(String walletId, String since)? poll,
    Future<List<PushSubscription>> Function()? subscriptions,
  }) : _poll = poll ?? ((id, since) => pollPush(walletId: id, since: since)),
       _subscriptions = subscriptions ?? pushSubscriptions;

  final Duration interval;
  final Future<PushPoll> Function(String walletId, String since) _poll;
  final Future<List<PushSubscription>> Function() _subscriptions;

  /// The last push seen for each wallet, or when polling began.
  final _since = <String, String>{};
  Timer? _timer;
  bool _busy = false;
  void Function(String walletId)? _onArrived;

  @override
  bool get supported => true;

  @override
  bool get notifiesItself => false;

  static String _now() => '${DateTime.now().millisecondsSinceEpoch ~/ 1000}';

  @override
  Future<void> start(void Function(String walletId) onArrived) async {
    _onArrived = onArrived;
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => pollNow());
    await pollNow();
  }

  /// Polls every subscribed wallet once.
  @visibleForTesting
  Future<void> pollNow() async {
    if (_busy) return;
    _busy = true;
    try {
      for (final s in await _subscriptions()) {
        final since = _since.putIfAbsent(s.walletId, _now);
        try {
          final result = await _poll(s.walletId, since);
          _since[s.walletId] = result.since;
          mark(s.walletId, PushState.ready);
          if (result.arrived > 0) _onArrived?.call(s.walletId);
        } on PushError {
          mark(s.walletId, PushState.unreachable);
        }
      }
    } on PushError {
      // Settings unreadable; try again next time.
    } finally {
      _busy = false;
    }
  }

  @override
  Future<PushState> subscribe(
    PushSubscription subscription, {
    required String title,
    required String body,
  }) async {
    _since[subscription.walletId] = _now();
    mark(subscription.walletId, PushState.waiting);
    unawaited(pollNow());
    return PushState.waiting;
  }

  @override
  Future<void> unsubscribe(String walletId) async {
    _since.remove(walletId);
    mark(walletId, null);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
