import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../platform/biometric_unlock.dart';
import '../../src/rust/api/network.dart';
import '../../src/rust/api/sync.dart';
import '../../src/rust/api/wallets.dart';

/// The wallet list and the wallets currently unlocked, shared by every
/// screen. Unlocked wallets are locked when the app goes to the background.
class WalletRegistry extends ChangeNotifier {
  WalletRegistry({this.biometric = const BiometricUnlock()});

  final BiometricUnlock biometric;

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
    _syncSubscriptions[id] = wallet.startSync().listen(
      (event) => notifier.value = event,
    );
  }

  void _stopSync(String id) {
    _syncSubscriptions.remove(id)?.cancel();
    _sync.remove(id)?.dispose();
  }

  Future<void> reload() async {
    _all = await listWallets();
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
    super.dispose();
  }
}
