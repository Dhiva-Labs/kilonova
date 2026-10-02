import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Locale;

import '../../l10n/generated/app_localizations.dart';
import '../../platform/biometric_unlock.dart';
import '../../platform/notifications.dart';
import '../../src/rust/api/preferences.dart' as prefs;
import '../../widgets/amount.dart';
import '../settings/price_feed.dart';
import '../../src/rust/api/network.dart';
import '../../src/rust/api/sync.dart';
import '../../src/rust/api/wallets.dart';

/// The wallet list and the wallets currently unlocked, shared by every
/// screen. Unlocked wallets are locked when the app goes to the background.
class WalletRegistry extends ChangeNotifier {
  WalletRegistry({
    this.biometric = const BiometricUnlock(),
    this.notifier = const Notifier(),
    PriceFeed? price,
  }) : price = price ?? PriceFeed();

  final BiometricUnlock biometric;
  final Notifier notifier;

  /// Notifications and background sync, both off until turned on.
  prefs.Preferences preferences = const prefs.Preferences(
    notifyIncoming: false,
    backgroundSync: false,
  );

  /// False while the app is not on screen (or its window is hidden).
  bool foreground = true;

  /// Incoming transactions each open wallet has already shown, so only new
  /// ones are announced.
  final Map<String, Set<String>> _seenIncoming = {};

  /// The optional fiat price, refreshed as wallets sync.
  final PriceFeed price;

  List<WalletSummary> _all = const [];
  final Map<String, OpenWallet> _open = {};
  final Map<String, ValueNotifier<SyncEvent?>> _sync = {};
  final Map<String, StreamSubscription<SyncEvent>> _syncSubscriptions = {};

  List<WalletSummary> on(Network network) =>
      _all.where((w) => w.network == network).toList(growable: false);

  WalletSummary? find(String id) => _all.where((w) => w.id == id).firstOrNull;

  OpenWallet? openWallet(String id) => _open[id];

  /// The latest sync report for an open wallet; `null` before the first.
  ValueListenable<SyncEvent?> syncOf(String id) =>
      _sync.putIfAbsent(id, () => ValueNotifier(null));

  /// Starts (or restarts after an error) background sync. Sync then keeps
  /// following the chain until the wallet is locked.
  void startSync(String id) {
    final wallet = _open[id];
    if (wallet == null) return;
    _syncSubscriptions[id]?.cancel();
    final notifier = _sync.putIfAbsent(id, () => ValueNotifier(null));
    _syncSubscriptions[id] = wallet.startSync().listen((event) {
      notifier.value = event;
      if (event.phase == SyncPhase.synced) price.refreshIfStale();
      _announceIncoming(id);
    });
  }

  /// Notifies about incoming payments that arrived since the last look,
  /// while the app is not in front and notifications are on. What a wallet
  /// already had when it was unlocked is never announced.
  void _announceIncoming(String id) {
    final wallet = _open[id];
    if (wallet == null) return;
    final incoming = {
      for (final item in wallet.history())
        if (item.incoming && !item.miner) item.txHash: item,
    };
    final seen = _seenIncoming[id];
    if (seen == null) {
      _seenIncoming[id] = incoming.keys.toSet();
      return;
    }
    final fresh = incoming.keys.where((tx) => !seen.contains(tx)).toList();
    seen.addAll(fresh);
    if (fresh.isEmpty || foreground || !preferences.notifyIncoming) return;
    final l = lookupAppLocalizations(const Locale('en'));
    final name = wallet.summary().name;
    for (final tx in fresh.take(3)) {
      final item = incoming[tx]!;
      notifier.payment(
        id: tx.hashCode & 0x7fffffff,
        title: l.notifyPaymentTitle(name),
        body: item.pending
            ? l.notifyPaymentPending(formatXmr(item.amount))
            : l.notifyPaymentBody(formatXmr(item.amount)),
        publicTitle: l.notifyPaymentPublic,
      );
    }
  }

  /// The app left the screen. Wallets lock, unless background sync is on
  /// (Android), in which case they keep syncing behind an ongoing
  /// notification.
  void paused() {
    foreground = false;
    if (preferences.backgroundSync &&
        notifier.supportsBackgroundSync &&
        _open.isNotEmpty) {
      final l = lookupAppLocalizations(const Locale('en'));
      notifier.startKeepAlive(
        title: l.keepAliveTitle,
        text: l.keepAliveText(_open.length),
      );
    } else {
      lockAll();
    }
  }

  void resumed() {
    foreground = true;
    notifier.stopKeepAlive();
  }

  void _stopSync(String id) {
    _syncSubscriptions.remove(id)?.cancel();
    _sync.remove(id)?.dispose();
    _seenIncoming.remove(id);
  }

  Future<void> reload() async {
    _all = await listWallets();
    preferences = await prefs.preferences();
    if (price.currency == null) await price.reload();
    notifyListeners();
  }

  /// Records a wallet that was just created, restored or unlocked.
  Future<void> opened(OpenWallet wallet) async {
    final id = wallet.summary().id;
    _open[id] = wallet;
    startSync(id);
    await reload();
  }

  void lock(String id) {
    _stopSync(id);
    _open.remove(id)?.lock();
    notifyListeners();
  }

  void lockAll() {
    if (_open.isEmpty) return;
    for (final id in _open.keys.toList()) {
      _stopSync(id);
      _open.remove(id)!.lock();
    }
    notifyListeners();
  }

  Future<void> removed(String id) async {
    _stopSync(id);
    _open.remove(id)?.lock();
    await biometric.disable(id);
    await reload();
  }

  @override
  void dispose() {
    lockAll();
    price.dispose();
    super.dispose();
  }
}
