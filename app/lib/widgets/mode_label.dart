import 'package:flutter/widgets.dart';

import '../l10n/generated/app_localizations.dart';
import '../src/rust/api/wallets.dart';

extension SyncModeLabel on SyncMode {
  String label(BuildContext context) {
    final l = AppLocalizations.of(context);
    return switch (this) {
      SyncMode.full => l.modeFull,
      SyncMode.lws => l.modeLws,
    };
  }

  String help(BuildContext context) {
    final l = AppLocalizations.of(context);
    return switch (this) {
      SyncMode.full => l.modeFullHelp,
      SyncMode.lws => l.modeLwsHelp,
    };
  }
}
