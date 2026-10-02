import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../src/rust/api/network.dart';
import '../../src/rust/api/wallets.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/amount.dart';
import '../../widgets/kn_button.dart';
import '../../widgets/kn_card.dart';
import '../../widgets/kn_icons.dart';
import '../../widgets/kn_sheet.dart';
import '../../widgets/network_label.dart';
import '../../widgets/sync_orbit.dart';
import '../../widgets/test_network_strip.dart';
import '../create/create_wallet_screen.dart';
import '../restore/restore_wallet_screen.dart';
import '../settings/settings_screen.dart';
import '../wallet/unlock_view.dart';
import '../wallet/wallet_dialogs.dart';
import '../wallet/wallet_view.dart';
import 'wallet_registry.dart';

/// Sidebar width on desktop.
const _sidebarWidth = 280.0;

/// The wallet list for the selected network. Desktop shows a sidebar beside
/// the selected wallet; phone shows the list, then pushes the wallet as its
/// own page.
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

  Future<void> _addWalletMenu() async {
    final l = AppLocalizations.of(context);
    final action = await showKnDialog<VoidCallback>(
      context,
      Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          KnButton.text(
            l.createWallet,
            onPressed: () => Navigator.of(context).pop(_create),
          ),
          const SizedBox(height: KnSpace.xs),
          KnButton.text(
            l.restoreWallet,
            onPressed: () => Navigator.of(context).pop(_restore),
          ),
        ],
      ),
    );
    action?.call();
  }

  void _openSettings() => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => SettingsScreen(registry: widget.registry),
    ),
  );

  void _select(String id) {
    if (context.isPhoneWidth) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => _WalletPage(id: id, registry: widget.registry),
        ),
      );
    } else {
      setState(() => _selected = id);
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
        final isPhone = context.isPhoneWidth;

        if (isPhone) {
          return Scaffold(
            appBar: AppBar(
              title: Text(l.walletsTitle),
              actions: [
                _NetworkMenu(network: network, onChanged: _switchNetwork),
                IconButton(
                  tooltip: l.settingsTooltip,
                  icon: const Icon(Icons.settings_outlined),
                  onPressed: _openSettings,
                ),
                const SizedBox(width: KnSpace.sm),
              ],
            ),
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TestNetworkStrip(network: network),
                Expanded(
                  child: wallets.isEmpty
                      ? _EmptyWallets(
                          network: network,
                          onCreate: _create,
                          onRestore: _restore,
                        )
                      : _WalletList(
                          wallets: wallets,
                          registry: widget.registry,
                          selectedId: null,
                          onSelect: _select,
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.all(KnSpace.md),
                  child: KnButton.secondary(
                    l.addWalletAction,
                    onPressed: _addWalletMenu,
                    expand: true,
                  ),
                ),
              ],
            ),
          );
        }

        return Scaffold(
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TestNetworkStrip(network: network),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      width: _sidebarWidth,
                      child: _Sidebar(
                        network: network,
                        wallets: wallets,
                        registry: widget.registry,
                        selectedId: selected?.id,
                        onSelect: _select,
                        onNetworkChanged: _switchNetwork,
                        onCreate: _create,
                        onRestore: _restore,
                        onAddWallet: _addWalletMenu,
                        onSettings: _openSettings,
                      ),
                    ),
                    Expanded(
                      child: _DetailPane(
                        key: ValueKey(selected?.id),
                        summary: selected,
                        registry: widget.registry,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _switchNetwork(Network n) {
    setState(() => _selected = null);
    widget.network.value = n;
  }
}

/// A single wallet as a full page, for phone width.
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
        final open = registry.openWallet(id);
        return Scaffold(
          appBar: AppBar(
            title: Text(summary.name),
            actions: [
              if (open != null) WalletMenu(wallet: open, registry: registry),
            ],
          ),
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TestNetworkStrip(network: summary.network),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(KnSpace.md),
                  child: open == null
                      ? UnlockView(wallet: summary, registry: registry)
                      : WalletView(
                          wallet: open,
                          registry: registry,
                          showHeader: false,
                        ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// The sidebar: network row, wallet list, bottom-pinned actions.
class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.network,
    required this.wallets,
    required this.registry,
    required this.selectedId,
    required this.onSelect,
    required this.onNetworkChanged,
    required this.onCreate,
    required this.onRestore,
    required this.onAddWallet,
    required this.onSettings,
  });

  final Network network;
  final List<WalletSummary> wallets;
  final WalletRegistry registry;
  final String? selectedId;
  final ValueChanged<String> onSelect;
  final ValueChanged<Network> onNetworkChanged;
  final VoidCallback onCreate;
  final VoidCallback onRestore;
  final VoidCallback onAddWallet;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = context.kn;
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(right: BorderSide(color: c.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              KnSpace.md,
              KnSpace.md,
              KnSpace.sm,
              KnSpace.sm,
            ),
            child: Row(
              children: [
                Eyebrow(l.walletsTitle),
                const Spacer(),
                _NetworkMenu(network: network, onChanged: onNetworkChanged),
              ],
            ),
          ),
          Expanded(
            child: wallets.isEmpty
                ? _EmptyWallets(
                    network: network,
                    onCreate: onCreate,
                    onRestore: onRestore,
                  )
                : _WalletList(
                    wallets: wallets,
                    registry: registry,
                    selectedId: selectedId,
                    onSelect: onSelect,
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(KnSpace.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                KnButton.text(l.addWalletAction, onPressed: onAddWallet),
                KnButton.text(l.settingsTooltip, onPressed: onSettings),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The quiet network menu button: the current network's name and a small
/// chevron. Switching networks is rare, so it stays out of the way.
class _NetworkMenu extends StatelessWidget {
  const _NetworkMenu({required this.network, required this.onChanged});

  final Network network;
  final ValueChanged<Network> onChanged;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = context.kn;
    final text = Theme.of(context).textTheme;
    return Semantics(
      label: l.networkSwitcherLabel,
      child: PopupMenuButton<Network>(
        onSelected: onChanged,
        itemBuilder: (_) => [
          for (final n in allNetworks())
            PopupMenuItem(value: n, child: Text(n.label(context))),
        ],
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: KnSpace.sm,
            vertical: KnSpace.xs,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(network.label(context), style: text.bodyMedium),
              const SizedBox(width: 2),
              Icon(Icons.expand_more, size: 16, color: c.textSecondary),
            ],
          ),
        ),
      ),
    );
  }
}

class _WalletList extends StatelessWidget {
  const _WalletList({
    required this.wallets,
    required this.registry,
    required this.selectedId,
    required this.onSelect,
  });

  final List<WalletSummary> wallets;
  final WalletRegistry registry;
  final String? selectedId;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = context.kn;
    return ListView(
      children: [
        for (final w in wallets)
          KnRow(
            selected: w.id == selectedId,
            title: Text(
              w.name,
              style: Theme.of(
                context,
              ).textTheme.titleLarge!.copyWith(fontSize: 16),
            ),
            subtitle: _WalletRowSubtitle(
              wallet: w,
              registry: registry,
              l: l,
              c: c,
            ),
            onTap: () => onSelect(w.id),
          ),
      ],
    );
  }
}

class _WalletRowSubtitle extends StatelessWidget {
  const _WalletRowSubtitle({
    required this.wallet,
    required this.registry,
    required this.l,
    required this.c,
  });

  final WalletSummary wallet;
  final WalletRegistry registry;
  final AppLocalizations l;
  final KnColors c;

  @override
  Widget build(BuildContext context) {
    final open = registry.openWallet(wallet.id);
    if (open == null) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          KnIcon(KnIcons.lock, size: 14, color: c.textSecondary),
          const SizedBox(width: 4),
          Text(
            l.walletLockedLabel,
            style: monoStyle(context, size: 13, color: c.textSecondary),
          ),
        ],
      );
    }
    // The balance moves as sync progresses, not only when the registry
    // itself changes, so this listens to the wallet's own sync events.
    return ValueListenableBuilder(
      valueListenable: registry.syncOf(wallet.id),
      builder: (context, _, _) => Text(
        '${formatXmrShort(open.balance().total)} XMR',
        style: monoStyle(context, size: 13, color: c.textSecondary),
      ),
    );
  }
}

/// Unlock form, unlocked wallet, or the empty hint, inside the detail pane.
class _DetailPane extends StatelessWidget {
  const _DetailPane({super.key, required this.summary, required this.registry});

  final WalletSummary? summary;
  final WalletRegistry registry;

  @override
  Widget build(BuildContext context) {
    final summary = this.summary;
    if (summary == null) return const _EmptyDetail();
    final open = registry.openWallet(summary.id);
    if (open == null) {
      return Padding(
        padding: const EdgeInsets.all(KnSpace.xl),
        child: Align(
          alignment: Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: UnlockView(wallet: summary, registry: registry),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(KnSpace.xl),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: WalletView(wallet: open, registry: registry),
      ),
    );
  }
}

class _EmptyDetail extends StatelessWidget {
  const _EmptyDetail();

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final c = context.kn;
    // SyncOrbit has no monochrome variant, so a scoped theme swap makes the
    // accent ring and dot read as `border` for this quiet empty state.
    final dimmed = KnColors(
      bg: c.bg,
      surface: c.surface,
      surfaceRaised: c.surfaceRaised,
      border: c.border,
      text: c.text,
      textSecondary: c.textSecondary,
      accent: c.border,
      onAccent: c.onAccent,
      accentHover: c.border,
      received: c.received,
      error: c.error,
      testnetStrip: c.testnetStrip,
      onTestnetStrip: c.onTestnetStrip,
    );
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Theme(
            data: Theme.of(context).copyWith(extensions: [KnTheme(dimmed)]),
            child: const SyncOrbit(progress: 0, size: 48),
          ),
          const SizedBox(height: KnSpace.md),
          Text(
            l.selectWalletHint,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium!.copyWith(color: c.textSecondary),
          ),
        ],
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
      padding: const EdgeInsets.all(KnSpace.md),
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
          KnButton.primary(l.createWallet, onPressed: onCreate, expand: true),
          const SizedBox(height: KnSpace.sm),
          KnButton.text(l.restoreWallet, onPressed: onRestore),
        ],
      ),
    );
  }
}
