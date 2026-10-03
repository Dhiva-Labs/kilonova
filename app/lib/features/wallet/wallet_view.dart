import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../src/rust/api/requests.dart';
import '../../src/rust/api/sync.dart';
import '../../src/rust/api/wallets.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/amount.dart';
import '../../widgets/kn_button.dart';
import '../../widgets/kn_card.dart';
import '../../widgets/kn_icons.dart';
import '../../widgets/mode_label.dart';
import '../cold/cold_screens.dart';
import '../send/send_screen.dart';
import '../wallets/wallet_registry.dart';
import 'history_list.dart';
import 'receive_screen.dart';
import 'request_screen.dart';
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

  Future<void> _scanColdRequest() =>
      coldScanRequest(context, widget.wallet, widget.registry);

  Future<void> _pair() => coldPair(context, widget.wallet, widget.registry);

  Future<void> _syncWithOffline() async {
    await coldSyncWithOffline(context, widget.wallet, widget.registry);
    if (mounted) setState(() {});
  }

  Widget _header(BuildContext context, WalletSummary summary) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.showHeader) ...[
          Row(
            children: [
              Expanded(child: Text(summary.name, style: text.headlineSmall)),
              WalletMenu(wallet: widget.wallet, registry: widget.registry),
            ],
          ),
          const SizedBox(height: KnSpace.xs),
        ],
        Text(
          [
            // A cold wallet never syncs, so its mode would mislead.
            summary.cold ? l.coldOfflineLabel : summary.mode.label(context),
            if (summary.viewOnly) l.viewOnlyTag,
          ].join(' · '),
          style: text.bodySmall,
        ),
      ],
    );
  }

  Widget _coldBody(BuildContext context, WalletSummary summary) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        _header(context, summary),
        const SizedBox(height: KnSpace.xl),
        KnCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const KnIcon(KnIcons.lock),
                  const SizedBox(width: KnSpace.sm),
                  Text(l.coldOfflineTitle, style: text.titleMedium),
                ],
              ),
              const SizedBox(height: KnSpace.sm),
              Text(l.coldOfflineBody, style: text.bodySmall),
            ],
          ),
        ),
        const SizedBox(height: KnSpace.lg),
        KnButton.primary(
          l.coldScanRequestAction,
          icon: const KnIcon(KnIcons.scan),
          onPressed: _scanColdRequest,
          expand: true,
        ),
        const SizedBox(height: KnSpace.sm),
        KnButton.secondary(l.coldPairAction, onPressed: _pair, expand: true),
        const SizedBox(height: KnSpace.sm),
        KnButton.secondary(
          l.receiveTitle,
          icon: const KnIcon(KnIcons.receive),
          onPressed: _receive,
          expand: true,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final summary = widget.wallet.summary();

    if (summary.cold) return _coldBody(context, summary);

    return ValueListenableBuilder<SyncEvent?>(
      valueListenable: widget.registry.syncOf(summary.id),
      builder: (context, event, _) {
        // Recomputed on every sync event, so the card appears as soon as
        // the watching wallet has scanned coins it cannot derive key
        // images for.
        final needsKeyImages = summary.viewOnly
            ? widget.wallet.coinsWithoutKeyImages()
            : 0;
        return ListView(
          padding: EdgeInsets.zero,
          children: [
            _header(context, summary),
            const SizedBox(height: KnSpace.xl),
            BalanceBlock(
              wallet: widget.wallet,
              prices: summary.network.isTestNetwork()
                  ? null
                  : widget.registry.price,
            ),
            const SizedBox(height: KnSpace.lg),
            if (needsKeyImages > 0) ...[
              KnCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l.coldSyncNeededCard(needsKeyImages),
                      style: text.bodyMedium,
                    ),
                    const SizedBox(height: KnSpace.sm),
                    KnButton.secondary(
                      l.coldSyncWithOfflineAction,
                      onPressed: _syncWithOffline,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: KnSpace.lg),
            ],
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                KnButton.primary(
                  l.sendAction,
                  icon: const KnIcon(KnIcons.send),
                  onPressed: _send,
                ),
                const SizedBox(width: KnSpace.sm),
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
              registry: widget.registry,
            ),
            if (widget.wallet.requests().isNotEmpty) ...[
              const SizedBox(height: KnSpace.xl),
              Eyebrow(l.requestsTitle),
              const SizedBox(height: KnSpace.sm),
              KnCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: withDividers([
                    for (final r in widget.wallet.requests())
                      KnRow(
                        title: Text(
                          r.label.isEmpty ? l.requestDefaultLabel : r.label,
                        ),
                        subtitle: Text(
                          requestStatusText(context, r),
                          style: r.status == RequestStatus.paid
                              ? TextStyle(color: context.kn.received)
                              : null,
                        ),
                        trailing: AmountText(r.amount),
                        onTap: () async {
                          await Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => RequestScreen(
                                wallet: widget.wallet,
                                request: r,
                              ),
                            ),
                          );
                          if (mounted) setState(() {});
                        },
                      ),
                  ]),
                ),
              ),
            ],
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
        );
      },
    );
  }
}
