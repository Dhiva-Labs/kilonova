import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../src/rust/api/network.dart';
import '../../src/rust/api/wallets.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/mode_label.dart';
import '../../widgets/network_label.dart';
import '../../widgets/test_network_strip.dart';
import '../create/create_wallet_screen.dart';
import '../restore/restore_wallet_screen.dart';
import '../settings/settings_screen.dart';
import '../wallet/unlock_view.dart';
import '../wallet/wallet_view.dart';
import 'wallet_registry.dart';

/// Width from which the list and the selected wallet sit side by side.
const _twoPaneWidth = 900.0;

/// The wallet list for the selected network. On wide windows the selected
/// wallet opens beside the list; on narrow ones it opens as its own page.
class WalletsScreen extends StatefulWidget {
  const WalletsScreen({
    super.key,
    required this.network,
    required this.registry,
  });

  final ValueNotifier<Network> network;
  final WalletRegistry registry;

  @override
  State<WalletsScreen> createState() => _WalletsScreenState();
}

class _WalletsScreenState extends State<WalletsScreen> {
  String? _selected;

  Future<void> _add(Widget Function(Network) screen) async {
    final id = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => screen(widget.network.value)),
    );
    if (id != null && mounted) _select(id);
  }

  void _create() =>
      _add((n) => CreateWalletScreen(network: n, registry: widget.registry));

  void _restore() =>
      _add((n) => RestoreWalletScreen(network: n, registry: widget.registry));

  void _select(String id) {
    if (MediaQuery.sizeOf(context).width >= _twoPaneWidth) {
      setState(() => _selected = id);
    } else {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => _WalletPage(id: id, registry: widget.registry),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([widget.network, widget.registry]),
      builder: (context, _) {
        final network = widget.network.value;
        final wallets = widget.registry.on(network);
        final selected = wallets.where((w) => w.id == _selected).firstOrNull;
        return Scaffold(
          appBar: AppBar(
            title: Text(l.walletsTitle),
            actions: [
              PopupMenuButton<VoidCallback>(
                tooltip: l.addWalletTooltip,
                icon: const Icon(Icons.add),
                onSelected: (action) => action(),
                itemBuilder: (_) => [
                  PopupMenuItem(value: _create, child: Text(l.createWallet)),
                  PopupMenuItem(value: _restore, child: Text(l.restoreWallet)),
                ],
              ),
              IconButton(
                tooltip: l.settingsTooltip,
                icon: const Icon(Icons.settings_outlined),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        SettingsScreen(prices: widget.registry.price),
                  ),
                ),
              ),
              const SizedBox(width: KnSpace.sm),
            ],
          ),
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TestNetworkStrip(network: network),
              Padding(
                padding: const EdgeInsets.all(KnSpace.md),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: _NetworkSwitcher(
                    selected: network,
                    onChanged: (n) {
                      setState(() => _selected = null);
                      widget.network.value = n;
                    },
                  ),
                ),
              ),
              const Divider(),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final list = wallets.isEmpty
                        ? _EmptyWallets(
                            network: network,
                            onCreate: _create,
                            onRestore: _restore,
                          )
                        : _WalletList(
                            wallets: wallets,
                            selectedId: selected?.id,
                            onSelect: _select,
                          );
                    if (constraints.maxWidth < _twoPaneWidth) return list;
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(width: 340, child: list),
                        const VerticalDivider(width: 1),
                        Expanded(
                          child: selected == null
                              ? _Hint(
                                  wallets.isEmpty ? null : l.selectWalletHint,
                                )
                              : _WalletDetail(
                                  key: ValueKey(selected.id),
                                  summary: selected,
                                  registry: widget.registry,
                                ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Unlock form or unlocked wallet, depending on the wallet's state.
class _WalletDetail extends StatelessWidget {
  const _WalletDetail({
    super.key,
    required this.summary,
    required this.registry,
  });

  final WalletSummary summary;
  final WalletRegistry registry;

  @override
  Widget build(BuildContext context) {
    final open = registry.openWallet(summary.id);
    return open == null
        ? UnlockView(wallet: summary, registry: registry)
        : WalletView(wallet: open, registry: registry);
  }
}

/// A single wallet as a full page, for narrow windows.
class _WalletPage extends StatelessWidget {
  const _WalletPage({required this.id, required this.registry});

  final String id;
  final WalletRegistry registry;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: registry,
      builder: (context, _) {
        final summary = registry.find(id);
        if (summary == null) {
          // Deleted from its own menu.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (context.mounted) Navigator.of(context).maybePop();
          });
          return const Scaffold();
        }
        return Scaffold(
          appBar: AppBar(),
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TestNetworkStrip(network: summary.network),
              Expanded(
                child: _WalletDetail(summary: summary, registry: registry),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _WalletList extends StatelessWidget {
  const _WalletList({
    required this.wallets,
    required this.selectedId,
    required this.onSelect,
  });

  final List<WalletSummary> wallets;
  final String? selectedId;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = context.kn;
    return ListView.separated(
      itemCount: wallets.length,
      separatorBuilder: (_, _) => const Divider(),
      itemBuilder: (context, i) {
        final w = wallets[i];
        return ListTile(
          selected: w.id == selectedId,
          selectedTileColor: c.border,
          selectedColor: c.text,
          tileColor: c.bg,
          title: Text(w.name),
          subtitle: Text(
            [w.mode.label(context), if (w.viewOnly) l.viewOnlyTag].join(' · '),
          ),
          onTap: () => onSelect(w.id),
        );
      },
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
  const _EmptyWallets({
    required this.network,
    required this.onCreate,
    required this.onRestore,
  });

  final Network network;
  final VoidCallback onCreate;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    return SingleChildScrollView(
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
          const SizedBox(height: KnSpace.lg),
          Wrap(
            spacing: KnSpace.sm,
            runSpacing: KnSpace.sm,
            children: [
              FilledButton(onPressed: onCreate, child: Text(l.createWallet)),
              TextButton(onPressed: onRestore, child: Text(l.restoreWallet)),
            ],
          ),
        ],
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.message);

  final String? message;

  @override
  Widget build(BuildContext context) {
    if (message == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.all(KnSpace.lg),
      child: Text(message!, style: Theme.of(context).textTheme.bodyMedium),
    );
  }
}
