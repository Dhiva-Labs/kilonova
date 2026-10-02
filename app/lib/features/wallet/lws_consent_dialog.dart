import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/kn_button.dart';

/// Asks before a wallet's private view key goes to a light wallet server.
/// Returns true only if the user agrees.
Future<bool> showLwsConsentDialog(BuildContext context, String server) async {
  final agreed = await showDialog<bool>(
    context: context,
    builder: (context) {
      final l = AppLocalizations.of(context);
      final text = Theme.of(context).textTheme;
      return AlertDialog(
        title: Text(l.lwsConsentTitle),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(server, style: monoStyle(context, size: 14)),
              const SizedBox(height: KnSpace.md),
              Text(l.lwsConsentBody(server), style: text.bodyMedium),
              const SizedBox(height: KnSpace.md),
              Text(l.lwsConsentAdvice, style: text.bodyMedium),
            ],
          ),
        ),
        actions: [
          KnButton.text(
            l.cancelAction,
            onPressed: () => Navigator.of(context).pop(false),
          ),
          KnButton.primary(
            l.lwsConsentAccept,
            onPressed: () => Navigator.of(context).pop(true),
          ),
        ],
      );
    },
  );
  return agreed ?? false;
}
