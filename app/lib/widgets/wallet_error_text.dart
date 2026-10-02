import 'package:flutter/widgets.dart';

import '../l10n/generated/app_localizations.dart';
import '../src/rust/api/wallets.dart';

/// The user-facing message for a [WalletError].
String walletErrorMessage(BuildContext context, WalletError error) {
  final l = AppLocalizations.of(context);
  return switch (error) {
    WalletError.wrongPassword => l.errorWrongPassword,
    WalletError.wrongWordCount => l.errorWrongWordCount,
    WalletError.unknownWord => l.errorUnknownWord,
    WalletError.badChecksum => l.errorBadChecksum,
    WalletError.unsupportedPolyseed => l.errorUnsupportedPolyseed,
    WalletError.malformedKey => l.errorMalformedKey,
    WalletError.invalidKey => l.errorInvalidKey,
    WalletError.badAddress => l.errorBadAddress,
    WalletError.viewKeyMismatch => l.errorViewKeyMismatch,
    WalletError.notStandardAddress => l.errorNotStandardAddress,
    WalletError.emptyName => l.errorEmptyName,
    WalletError.damaged => l.errorDamaged,
    WalletError.newerVersion => l.errorNewerVersion,
    WalletError.notFound => l.errorNotFound,
    WalletError.storage => l.errorStorage,
    WalletError.notInitialized => l.errorNotInitialized,
  };
}
