import 'dart:io';

import 'package:flutter/services.dart';

/// Why a biometric unlock did not return a password.
enum BiometricFailure {
  /// The user closed the prompt.
  cancelled,

  /// New fingerprints or faces were enrolled, so the stored password was
  /// erased. The wallet must be unlocked with its password.
  invalidated,

  /// Anything else: too many attempts, hardware error, not enabled.
  failed,
}

class BiometricException implements Exception {
  const BiometricException(this.failure);
  final BiometricFailure failure;
}

/// Unlocking a wallet with a fingerprint or face, on Android.
///
/// The wallet password is encrypted under an Android Keystore key that can
/// only be used right after a strong biometric check; see BiometricVault.kt.
/// On other platforms everything reports "not available".
class BiometricUnlock {
  const BiometricUnlock();

  static const _channel = MethodChannel('kilonova/biometric');

  Future<bool> isAvailable() async =>
      Platform.isAndroid &&
      (await _channel.invokeMethod<bool>('isAvailable') ?? false);

  Future<bool> isEnabled(String walletId) async =>
      Platform.isAndroid &&
      (await _channel.invokeMethod<bool>('isEnabled', {'id': walletId}) ??
          false);

  /// Stores [password] behind a biometric check. Returns false if the user
  /// cancelled the prompt.
  Future<bool> enable(
    String walletId,
    String password, {
    required String title,
    required String cancel,
  }) async {
    try {
      return await _channel.invokeMethod<bool>('enable', {
            'id': walletId,
            'password': password,
            'title': title,
            'cancel': cancel,
          }) ??
          false;
    } on PlatformException catch (e) {
      if (e.code == 'cancelled') return false;
      rethrow;
    }
  }

  /// Shows the biometric prompt and returns the wallet password.
  ///
  /// Throws [BiometricException] when no password comes back.
  Future<String> unlock(
    String walletId, {
    required String title,
    required String cancel,
  }) async {
    try {
      final password = await _channel.invokeMethod<String>('unlock', {
        'id': walletId,
        'title': title,
        'cancel': cancel,
      });
      if (password == null) {
        throw const BiometricException(BiometricFailure.failed);
      }
      return password;
    } on PlatformException catch (e) {
      throw BiometricException(switch (e.code) {
        'cancelled' => BiometricFailure.cancelled,
        'invalidated' => BiometricFailure.invalidated,
        _ => BiometricFailure.failed,
      });
    }
  }

  Future<void> disable(String walletId) async {
    if (Platform.isAndroid) {
      await _channel.invokeMethod<void>('disable', {'id': walletId});
    }
  }
}
