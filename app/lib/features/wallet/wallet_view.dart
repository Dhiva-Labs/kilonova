import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../src/rust/api/sync.dart';
import '../../src/rust/api/wallets.dart';
import '../../theme/tokens.dart';
import '../../widgets/kn_button.dart';
import '../../widgets/kn_card.dart';
import '../../widgets/kn_icons.dart';
import '../../widgets/mode_label.dart';
import '../send/send_screen.dart';
import '../wallets/wallet_registry.dart';
import 'history_list.dart';
import 'receive_screen.dart';
import 'sync_panel.dart';
import 'tx_details_screen.dart';
import 'wallet_dialogs.dart';

/// An unlocked wallet: name and header, balance, sync status, actions and
/// history. Receiving addresses live in [ReceiveScreen].
class WalletView extends StatefulWidget {
  const WalletView({
    super.key,
    required this.wallet,
    required this.registry,
    this.showHeader = true,
  });

  final OpenWallet wallet;
  final WalletRegistry registry;

  /// False when the caller already shows the name and the more menu in its
  /// own app bar (the phone wallet page), so this does not repeat them.
  final bool showHeader;

  @override
  State<WalletView> createState() => _WalletViewState();
}

class _WalletViewState extends State<WalletView> {
  Future<void> _send() async {
    final l = AppLocalizations.of(context);
    final sent = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) =>
            SendScreen(wallet: widget.wallet, registry: widget.registry),
      ),
    );
    if (sent != true || !mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(l.sentNotice)));
  }

  Future<void> _receive() => openReceiveScreen(context, wallet: widget.wallet);

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final summary = widget.wallet.summary();

    return ValueListenableBuilder<SyncEvent?>(
      valueListenable: widget.registry.syncOf(summary.id),
      builder: (context, event, _) => ListView(
        padding: EdgeInsets.zero,
        children: [
          if (widget.showHeader) ...[
            Row(
              children: [
                Expanded(
                  child: Text(summary.name, style: text.headlineSmall),
                ),
                WalletMenu(wallet: widget.wallet, registry: widget.registry),
              ],
            ),
            const SizedBox(height: KnSpace.xs),
          ],
          Text(
            [
              summary.mode.label(context),
              if (summary.viewOnly) l.viewOnlyTag,
            ].join(' · '),
            style: text.bodySmall,
          ),
          const SizedBox(height: KnSpace.xl),
          BalanceBlock(
            wallet: widget.wallet,
            prices: summary.network.isTestNetwork()
                ? null
                : widget.registry.price,
          ),
          const SizedBox(height: KnSpace.lg),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!summary.viewOnly) ...[
                KnButton.primary(
                  l.sendAction,
                  icon: const KnIcon(KnIcons.send),
                  onPressed: _send,
                ),
                const SizedBox(width: KnSpace.sm),
              ],
              KnButton.secondary(
                l.receiveTitle,
                icon: const KnIcon(KnIcons.receive),
                onPressed: _receive,
              ),
            ],
          ),
          const SizedBox(height: KnSpace.lg),
          SyncLine(
            wallet: widget.wallet,
            event: event,
            onRetry: () => widget.registry.startSync(summary.id),
          ),
          const SizedBox(height: KnSpace.xl),
          Eyebrow(l.historyTitle),
          const SizedBox(height: KnSpace.sm),
          HistoryList(
            items: widget.wallet.history(),
            onOpen: (item) async {
              await Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => TxDetailsScreen(
                    wallet: widget.wallet,
                    item: item,
                    biometric: widget.registry.biometric,
                  ),
                ),
              );
              if (mounted) setState(() {});
            },
          ),
        ],
      ),
    );
  }
}
