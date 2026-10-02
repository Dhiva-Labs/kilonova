import 'package:flutter/widgets.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../src/rust/api/cold.dart';

/// The user-facing message for a [ColdFailure].
String coldFailureMessage(BuildContext context, ColdFailure failure) {
  final l = AppLocalizations.of(context);
  return switch (failure) {
    ColdFailure.notColdData => l.coldFailureNotColdData,
    ColdFailure.wrongWallet => l.coldFailureWrongWallet,
    ColdFailure.wrongNetwork => l.coldFailureWrongNetwork,
    ColdFailure.wrongKind => l.coldFailureWrongKind,
    ColdFailure.damaged => l.coldFailureDamaged,
    ColdFailure.notOurs => l.coldFailureNotOurs,
    ColdFailure.changeElsewhere => l.coldFailureChangeElsewhere,
    ColdFailure.badAddress => l.sendAddressInvalid,
    ColdFailure.feeTooHigh => l.sendFeeTooHigh,
    ColdFailure.inconsistent => l.coldFailureInconsistent,
    ColdFailure.viewOnly => l.sendViewOnly,
    ColdFailure.notWatching => l.coldFailureNotWatching,
    ColdFailure.isCold => l.coldFailureIsCold,
    ColdFailure.wrongPassword => l.errorWrongPassword,
    ColdFailure.alreadyUsed => l.coldFailureAlreadyUsed,
    ColdFailure.send => l.sendBuildFailed,
    ColdFailure.locked || ColdFailure.storage => l.errorStorage,
  };
}
