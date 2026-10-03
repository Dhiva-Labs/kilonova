import 'dart:io';

import 'package:flutter/services.dart';

/// What a background check's notification says for one wallet. [body] and
/// [pending] hold `{amount}` where the amount goes.
class CheckLabels {
  const CheckLabels({
    required this.title,
    required this.body,
    required this.pending,
  });

  final String title;
  final String body;
  final String pending;

  Map<String, String> toMap() => {
    'title': title,
    'body': body,
    'pending': pending,
  };
}

/// Android: checks the wallets the owner chose for incoming payments about
/// every 15 minutes while Kilonova is closed (WorkManager, no Flutter
/// engine; see BackgroundChecks.kt). Each chosen wallet's watch state
/// (view key, never the spend key or seed) is kept encrypted with a
/// Keystore key. Off until the owner agrees on the consent screen.
class BackgroundChecks {
  const BackgroundChecks();

  static const _android = MethodChannel('kilonova/background');

  /// Whether checks with the app closed are possible here.
  bool get supported => Platform.isAndroid;

  /// The wallets being checked, by id.
  Future<List<String>> wallets() async {
    if (!supported) return const [];
    final ids = await _android.invokeListMethod<String>('checkWallets');
    return ids ?? const [];
  }

  /// Starts checking a wallet with [state] from `exportWatchState`.
  /// [walletDir] is the app's wallet directory, whose node and proxy
  /// settings the checks follow.
  Future<void> watch(String walletId, Uint8List state, String walletDir) =>
      _android.invokeMethod<void>('checkWallet', {
        'id': walletId,
        'state': state,
        'dir': walletDir,
      });

  /// What notifications say, per wallet id.
  Future<void> labels(Map<String, CheckLabels> wallets, String publicTitle) =>
      _android.invokeMethod<void>('checkLabels', {
        'wallets': {for (final e in wallets.entries) e.key: e.value.toMap()},
        'publicTitle': publicTitle,
      });

  /// Stops checking a wallet and deletes its watch state; with none left,
  /// the Keystore key goes too and the periodic work is cancelled.
  Future<void> forget(String walletId) =>
      _android.invokeMethod<void>('stopChecking', {'id': walletId});

  /// Stops all checks and deletes every watch state and the key.
  Future<void> forgetAll() => _android.invokeMethod<void>('stopCheckingAll');

  /// Whether Android lets Kilonova run without battery limits.
  Future<bool> batteryUnrestricted() async =>
      await _android.invokeMethod<bool>('batteryUnrestricted') ?? false;

  /// Opens the system list where the owner can let Kilonova run without
  /// battery limits. Returns whether it opened.
  Future<bool> openBatterySettings() async =>
      await _android.invokeMethod<bool>('openBatterySettings') ?? false;
}
