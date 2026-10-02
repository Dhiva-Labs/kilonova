import 'package:flutter/widgets.dart';

import '../l10n/generated/app_localizations.dart';
import '../src/rust/api/network.dart';

extension NetworkLabel on Network {
  String label(BuildContext context) {
    final l = AppLocalizations.of(context);
    return switch (this) {
      Network.mainnet => l.networkMainnet,
      Network.stagenet => l.networkStagenet,
      Network.testnet => l.networkTestnet,
    };
  }
}
