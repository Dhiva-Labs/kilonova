import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../src/rust/api/network.dart';
import '../../theme/tokens.dart';
import '../../widgets/network_label.dart';
import '../../widgets/test_network_strip.dart';
import '../settings/settings_screen.dart';

/// The wallet list, filtered by the selected network.
class WalletsScreen extends StatelessWidget {
  const WalletsScreen({super.key, required this.network});

  /// The network the list is showing. Changed by the switcher at the top.
  final ValueNotifier<Network> network;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ValueListenableBuilder<Network>(
      valueListenable: network,
      builder: (context, selected, _) => Scaffold(
        appBar: AppBar(
          title: Text(l.walletsTitle),
          actions: [
            IconButton(
              tooltip: l.settingsTooltip,
              icon: const Icon(Icons.settings_outlined),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
              ),
            ),
            const SizedBox(width: KnSpace.sm),
          ],
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TestNetworkStrip(network: selected),
            Padding(
              padding: const EdgeInsets.all(KnSpace.md),
              child: Align(
                alignment: Alignment.centerLeft,
                child: _NetworkSwitcher(
                  selected: selected,
                  onChanged: (n) => network.value = n,
                ),
              ),
            ),
            const Divider(),
            Expanded(child: _EmptyWallets(network: selected)),
          ],
        ),
      ),
    );
  }
}

class _NetworkSwitcher extends StatelessWidget {
  const _NetworkSwitcher({required this.selected, required this.onChanged});

  final Network selected;
  final ValueChanged<Network> onChanged;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: AppLocalizations.of(context).networkSwitcherLabel,
      child: SegmentedButton<Network>(
        showSelectedIcon: false,
        segments: [
          for (final n in allNetworks())
            ButtonSegment(value: n, label: Text(n.label(context))),
        ],
        selected: {selected},
        onSelectionChanged: (s) => onChanged(s.single),
      ),
    );
  }
}

class _EmptyWallets extends StatelessWidget {
  const _EmptyWallets({required this.network});

  final Network network;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    return Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(KnSpace.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l.noWalletsTitle(network.label(context)),
                style: text.titleMedium,
              ),
              const SizedBox(height: KnSpace.sm),
              Text(l.noWalletsBody, style: text.bodyMedium),
            ],
          ),
        ),
      ),
    );
  }
}
