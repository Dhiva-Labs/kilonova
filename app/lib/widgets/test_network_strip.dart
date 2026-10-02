import 'package:flutter/material.dart';

import '../l10n/generated/app_localizations.dart';
import '../src/rust/api/network.dart';
import '../theme/theme.dart';
import '../theme/tokens.dart';
import 'network_label.dart';

/// The solid strip every stagenet or testnet screen carries, so test coins
/// are never mistaken for real ones. Renders nothing on mainnet.
class TestNetworkStrip extends StatelessWidget {
  const TestNetworkStrip({super.key, required this.network});

  final Network network;

  @override
  Widget build(BuildContext context) {
    if (!network.isTestNetwork()) return const SizedBox.shrink();
    final c = context.kn;
    return Container(
      width: double.infinity,
      color: c.testnetStrip,
      padding: const EdgeInsets.symmetric(
        horizontal: KnSpace.md,
        vertical: KnSpace.sm,
      ),
      child: Text(
        AppLocalizations.of(context).testNetworkStrip(network.label(context)),
        style: Theme.of(
          context,
        ).textTheme.labelLarge!.copyWith(color: c.onTestnetStrip),
      ),
    );
  }
}
