import 'package:flutter/foundation.dart';

import '../../platform/biometric_unlock.dart';
import '../../src/rust/api/network.dart';
import '../../src/rust/api/wallets.dart';

/// The wallet list and the wallets currently unlocked, shared by every
/// screen. Unlocked wallets are locked when the app goes to the background.
class WalletRegistry extends ChangeNotifier {
  WalletRegistry({this.biometric = const BiometricUnlock()});

  final BiometricUnlock biometric;

  List<WalletSummary> _all = const [];
  final Map<String, OpenWallet> _open = {};

  List<WalletSummary> on(Network network) =>
      _all.where((w) => w.network == network).toList(growable: false);

  WalletSummary? find(String id) => _all.where((w) => w.id == id).firstOrNull;

  OpenWallet? openWallet(String id) => _open[id];

  Future<void> reload() async {
    _all = await listWallets();
    notifyListeners();
  }

  /// Records a wallet that was just created, restored or unlocked.
  Future<void> opened(OpenWallet wallet) async {
    _open[wallet.summary().id] = wallet;
    await reload();
  }

  void lock(String id) {
    _open.remove(id)?.lock();
    notifyListeners();
  }

  void lockAll() {
    if (_open.isEmpty) return;
    for (final wallet in _open.values) {
      wallet.lock();
    }
    _open.clear();
    notifyListeners();
  }

  Future<void> removed(String id) async {
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
