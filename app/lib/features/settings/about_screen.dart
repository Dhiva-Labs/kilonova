import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../src/rust/api/core.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/kn_button.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final c = context.kn;
    final phone = context.isPhoneWidth;

    Widget row(String label, String value, {bool mono = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: KnSpace.sm),
      child: Row(
        children: [
          SizedBox(
            width: 140,
            child: Text(
              label,
              style: text.bodyMedium!.copyWith(color: c.textSecondary),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: mono ? monoStyle(context) : text.bodyMedium,
            ),
          ),
        ],
      ),
    );

    return Scaffold(
      appBar: AppBar(title: Text(l.aboutTitle)),
      body: SingleChildScrollView(
        padding: EdgeInsets.all(phone ? KnSpace.md : KnSpace.xl),
        child: Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(KnRadius.md),
                  child: Image.asset(
                    'assets/icon/kilonova-256.png',
                    width: 64,
                    height: 64,
                    filterQuality: FilterQuality.medium,
                  ),
                ),
                const SizedBox(height: KnSpace.md),
                Text('Kilonova', style: text.headlineSmall),
                const SizedBox(height: KnSpace.sm),
                Text(l.aboutDescription, style: text.bodyLarge),
                const SizedBox(height: KnSpace.lg),
                row(l.aboutCoreVersion, coreInfo().version, mono: true),
                row(l.aboutLicense, l.aboutLicenseValue),
                row(l.aboutSource, l.aboutSourceValue, mono: true),
                const SizedBox(height: KnSpace.lg),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.warning_amber_outlined,
                      color: c.textSecondary,
                      size: 20,
                    ),
                    const SizedBox(width: KnSpace.sm),
                    Expanded(
                      child: Text(l.aboutUnaudited, style: text.bodyMedium),
                    ),
                  ],
                ),
                const SizedBox(height: KnSpace.lg),
                KnButton.text(
                  l.aboutOpenSourceLicenses,
                  onPressed: () => showLicensePage(
                    context: context,
                    applicationName: l.appTitle,
                    applicationVersion: coreInfo().version,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
