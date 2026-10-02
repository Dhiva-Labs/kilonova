import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../src/rust/api/nodes.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/kn_button.dart';
import '../../widgets/kn_sheet.dart';

/// Shows the certificate an https node presents and lets the user trust it
/// (for nodes they run with a self-signed certificate). Returns true if it
/// is now trusted.
Future<bool> offerToTrustCertificate(BuildContext context, String url) async {
  final CertificateDetails details;
  try {
    details = await serverCertificateInfo(url: url);
  } on NodeError {
    return false;
  }
  if (!context.mounted || details.publiclyTrusted) return false;
  final l = AppLocalizations.of(context);
  final trust = await showKnDialog<bool>(
    context,
    _CertificateBody(url: url, details: details),
    title: l.certTitle,
    actions: [
      KnButton.text(
        l.cancelAction,
        onPressed: () => Navigator.pop(context, false),
      ),
      KnButton.primary(
        l.certTrustAction,
        onPressed: () => Navigator.pop(context, true),
      ),
    ],
  );
  if (trust != true) return false;
  await trustCertificate(url: url, fingerprint: details.fingerprint);
  return true;
}

class _CertificateBody extends StatelessWidget {
  const _CertificateBody({required this.url, required this.details});

  final String url;
  final CertificateDetails details;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final pinned = details.pinned;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          pinned == null ? l.certBody(url) : l.certChangedBody(url),
          style: text.bodyMedium,
        ),
        const SizedBox(height: KnSpace.md),
        Text(l.certFingerprintLabel, style: text.labelMedium),
        const SizedBox(height: KnSpace.xs),
        SelectableText(
          details.fingerprint,
          style: monoStyle(context, size: 12),
        ),
        if (pinned != null) ...[
          const SizedBox(height: KnSpace.md),
          Text(l.certPinnedLabel, style: text.labelMedium),
          const SizedBox(height: KnSpace.xs),
          SelectableText(pinned, style: monoStyle(context, size: 12)),
        ],
        const SizedBox(height: KnSpace.md),
        Text(l.certAdvice, style: text.bodySmall),
      ],
    );
  }
}
