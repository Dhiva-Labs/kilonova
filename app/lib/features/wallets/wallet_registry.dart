import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Locale;

import '../../l10n/generated/app_localizations.dart';
import '../../platform/biometric_unlock.dart';
import '../../platform/desktop_shell.dart';
import '../../platform/notifications.dart';
import '../../platform/push.dart';
import '../../src/rust/api/push.dart' show removePushSubscription;
import '../../src/rust/api/preferences.dart' as prefs;
import '../../widgets/amount.dart';
import '../settings/price_feed.dart';
import '../../src/rust/api/network.dart';
import '../../src/rust/api/requests.dart';
import '../../src/rust/api/sync.dart';
import '../../src/rust/api/wallets.dart';
import '../cold/cold_transport.dart';
import '../settings/backup_files.dart';

/// The wallet list and the wallets currently unlocked, shared by every
/// screen. Unlocked wallets are locked when the app goes to the background.
class WalletRegistry extends ChangeNotifier {
  WalletRegistry({
    this.biometric = const BiometricUnlock(),
    this.notifier = const Notifier(),
    this.cold = const ColdTransport(),
    this.backupFiles = const BackupFiles(),
    this.push = const NoPush(),
    PriceFeed? price,
  }) : price = price ?? PriceFeed();

  final BiometricUnlock biometric;
  final Notifier notifier;

  /// Payment pushes from the owner's own server.
  final PushChannel push;

  /// Desktop: closing the window can keep the app running (see
  /// [windowClosing]), so leaving the screen never locks by itself when
  /// the owner chose to keep syncing.
  bool keepsSyncingHidden = false;

  /// Desktop: whether the system shows tray icons.
  bool hasTray = false;

  /// How scans and file saves move cold wallet messages; a fake in tests.
  final ColdTransport cold;

  /// Where backups are saved and read from; a fake in tests.
  final BackupFiles backupFiles;

  /// Notifications and background sync, both off until turned on.
  prefs.Preferences get preferences => _preferences;
  set preferences(prefs.Preferences value) {
    final changed = value.notifyIncoming != _preferences.notifyIncoming;
    _preferences = value;
    if (changed) _reportAnnouncing();
  }

  prefs.Preferences _preferences = const prefs.Preferences(
    notifyIncoming: false,
    backgroundSync: false,
    confirmLwsPayments: false,
  );

  /// False while the app is not on screen (or its window is hidden). Sync
  /// is told too, so wallets at the chain tip look for blocks less often
  /// in the background.
  bool get foreground => _foreground;
  set foreground(bool value) {
    if (value == _foreground) return;
    _foreground = value;
    setSyncPace(foreground: value);
  }

  bool _foreground = true;

  /// Incoming transactions each open wallet has already shown, so only new
  /// ones are announced.
  final Map<String, Set<String>> _seenIncoming = {};

  /// Each open wallet's requests, by id, as they stood last time sync
  /// reported, so a request turning paid can be announced once.
  final Map<String, Map<String, RequestStatus>> _requestStatuses = {};

  /// The optional fiat price, refreshed as wallets sync.
  final PriceFeed price;

  List<WalletSummary> _all = const [];
  final Map<String, OpenWallet> _open = {};
  final Map<String, ValueNotifier<SyncEvent?>> _sync = {};
  final Map<String, StreamSubscription<SyncEvent>> _syncSubscriptions = {};

  /// Every wallet, on every network, in creation order.
  List<WalletSummary> get all => _all;

  List<WalletSummary> on(Network network) =>
      _all.where((w) => w.network == network).toList(growable: false);

  WalletSummary? find(String id) => _all.where((w) => w.id == id).firstOrNull;

  OpenWallet? openWallet(String id) => _open[id];

  /// The latest sync report for an open wallet; `null` before the first.
  ValueListenable<SyncEvent?> syncOf(String id) =>
      _sync.putIfAbsent(id, () => ValueNotifier(null));

  /// Starts (or restarts after an error) background sync. Sync then keeps
  /// following the chain until the wallet is locked. A cold wallet never
  /// goes online, so this does nothing for one.
  void startSync(String id) {
    final wallet = _open[id];
    if (wallet == null || wallet.summary().cold) return;
    _syncSubscriptions[id]?.cancel();
    final notifier = _sync.putIfAbsent(id, () => ValueNotifier(null));
    _syncSubscriptions[id] = wallet.startSync().listen((event) {
      notifier.value = event;
      if (event.phase == SyncPhase.synced) price.refreshIfStale();
      _announceIncoming(id);
      _announceRequestsPaid(id);
    });
  }

  /// Notifies about requests that just turned paid, while the app is not
  /// in front and notifications are on. A request already paid when the
  /// wallet was unlocked is never announced.
  void _announceRequestsPaid(String id) {
    final wallet = _open[id];
    if (wallet == null) return;
    final requests = wallet.requests();
    final previous = _requestStatuses[id];
    if (previous == null) {
      _requestStatuses[id] = {for (final r in requests) r.id: r.status};
      return;
    }
    final newlyPaid = requests.where(
      (r) =>
          r.status == RequestStatus.paid &&
          previous[r.id] != RequestStatus.paid,
    );
    for (final r in requests) {
      previous[r.id] = r.status;
    }
    if (foreground || !preferences.notifyIncoming) return;
    final l = lookupAppLocalizations(const Locale('en'));
    for (final r in newlyPaid.take(3)) {
      final label = r.label.isEmpty ? '${formatXmr(r.amount)} XMR' : r.label;
      notifier.payment(
        id: r.id.hashCode & 0x7fffffff,
        title: l.notifyRequestPaidTitle(label),
        body: l.notifyPaymentBody(formatXmr(r.amount)),
        publicTitle: l.notifyPaymentPublic,
      );
    }
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
  /// notification, or the owner keeps them syncing with the window closed
  /// (desktop).
  void paused() {
    foreground = false;
    if (preferences.backgroundSync && keepsSyncingHidden) return;
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

  /// Desktop: the owner closed the window. Wallets lock and the app quits,
  /// unless they keep syncing with the window closed (the same setting as
  /// Android's background sync); then the window hides to the tray, or
  /// is minimized where there is no tray, and notifications follow the
  /// usual rules for an app that is not in front.
  CloseAction windowClosing({required bool hasTray}) {
    final action = closeAction(
      keepSyncing: preferences.backgroundSync,
      hasTray: hasTray,
    );
    if (action == CloseAction.quit) {
      lockAll();
    } else {
      foreground = false;
    }
    return action;
  }

  /// Desktop: the window is back on screen.
  void windowOpened() => foreground = true;

  /// Tells the push channel which wallets announce payments themselves.
  void _reportAnnouncing() {
    final ids = preferences.notifyIncoming ? _open.keys.toSet() : <String>{};
    push.announcing(ids).catchError((Object _) {});
  }

  /// Starts listening for payment pushes from the owner's server.
  Future<void> startPush() => push.start(pushArrived);

  /// A push said something arrived for [walletId]. An unlocked wallet
  /// syncs right away and announces what came as usual; for a locked one
  /// (or with payment notifications off) a notification says only that
  /// something arrived, since the push carries no amount.
  void pushArrived(String walletId) {
    final summary = find(walletId);
    if (summary == null) return;
    final open = _open.containsKey(walletId);
    if (open) startSync(walletId);
    if (push.notifiesItself || foreground) return;
    if (open && preferences.notifyIncoming) return;
    final l = lookupAppLocalizations(const Locale('en'));
    notifier.payment(
      id: walletId.hashCode & 0x7fffffff,
      title: l.pushArrivedTitle(summary.name),
      body: l.pushArrivedBody,
      publicTitle: l.notifyPaymentPublic,
    );
  }

  void _stopSync(String id) {
    _syncSubscriptions.remove(id)?.cancel();
    _sync.remove(id)?.dispose();
    _seenIncoming.remove(id);
    _requestStatuses.remove(id);
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
    _reportAnnouncing();
  }

  void lock(String id) {
    _stopSync(id);
    _open.remove(id)?.lock();
    _reportAnnouncing();
    notifyListeners();
  }

  void lockAll() {
    if (_open.isEmpty) return;
    for (final id in _open.keys.toList()) {
      _stopSync(id);
      _open.remove(id)!.lock();
    }
    _reportAnnouncing();
    notifyListeners();
  }

  Future<void> removed(String id) async {
    _stopSync(id);
    _open.remove(id)?.lock();
    await biometric.disable(id);
    try {
      await push.unsubscribe(id);
      await removePushSubscription(walletId: id);
    } on Object {
      // The wallet is gone either way; a stale topic only goes unused.
    }
    await reload();
  }

  @override
  void dispose() {
    lockAll();
    push.dispose();
    price.dispose();
    super.dispose();
  }
}
