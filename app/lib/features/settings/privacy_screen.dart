import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/markdown_view.dart';

/// Asset path of the bundled privacy policy. A test keeps it identical to
/// PRIVACY.md at the repository root.
const privacyPolicyAsset = 'assets/legal/PRIVACY.md';

/// The privacy policy, bundled with the app so it reads offline.
class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final phone = context.isPhoneWidth;
    return Scaffold(
      appBar: AppBar(title: Text(AppLocalizations.of(context).privacyTitle)),
      body: FutureBuilder<String>(
        future: rootBundle.loadString(privacyPolicyAsset),
        builder: (context, snapshot) {
          final source = snapshot.data;
          if (source == null) return const SizedBox.shrink();
          return SingleChildScrollView(
            padding: EdgeInsets.all(phone ? KnSpace.md : KnSpace.xl),
            child: Align(
              alignment: Alignment.topLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: MarkdownView(source: source),
              ),
            ),
          );
        },
      ),
    );
  }
}
