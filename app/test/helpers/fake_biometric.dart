import 'package:kilonova/platform/biometric_unlock.dart';

/// Stands in for the Android Keystore and BiometricPrompt.
class FakeBiometric implements BiometricUnlock {
  final Map<String, String> stored = {};

  /// What the next prompt does; `null` means the user authenticates.
  BiometricFailure? nextFailure;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<bool> isEnabled(String walletId) async => stored.containsKey(walletId);

  @override
  Future<bool> enable(
    String walletId,
    String password, {
    required String title,
    required String cancel,
  }) async {
    if (nextFailure == BiometricFailure.cancelled) return false;
    stored[walletId] = password;
    return true;
  }

  @override
  Future<String> unlock(
    String walletId, {
    required String title,
    required String cancel,
  }) async {
    final failure = nextFailure;
    if (failure != null) {
      if (failure == BiometricFailure.invalidated) stored.remove(walletId);
      throw BiometricException(failure);
    }
    return stored[walletId] ??
        (throw const BiometricException(BiometricFailure.failed));
  }

  @override
  Future<void> disable(String walletId) async => stored.remove(walletId);
}
