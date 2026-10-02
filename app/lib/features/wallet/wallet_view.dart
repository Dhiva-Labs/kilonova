import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../src/rust/api/wallets.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../../src/rust/api/sync.dart';
import '../../widgets/mode_label.dart';
import '../../widgets/amount.dart';
import '../send/monero_uri.dart';
import '../send/send_screen.dart';
import '../wallets/wallet_registry.dart';
import 'history_list.dart';
import 'tx_details_screen.dart';
import 'sync_panel.dart';
import 'wallet_dialogs.dart';

/// An unlocked wallet: balance, sync status, history, receiving addresses
/// and wallet actions.
class WalletView extends StatefulWidget {
  const WalletView({super.key, required this.wallet, required this.registry});

  final OpenWallet wallet;
  final WalletRegistry registry;

  @override
  State<WalletView> createState() => _WalletViewState();
}

class _WalletViewState extends State<WalletView> {
  late List<AddressRow> _addresses = widget.wallet.addresses();

  Future<void> _newAddress() async {
    final label = await askForText(
      context,
      title: AppLocalizations.of(context).newAddressAction,
      hint: AppLocalizations.of(context).newAddressLabelHint,
    );
    if (label == null) return;
    await widget.wallet.newAddress(label: label);
    setState(() => _addresses = widget.wallet.addresses());
  }

  Future<void> _editLabel(AddressRow row) async {
    final l = AppLocalizations.of(context);
    final label = await askForText(
      context,
      title: l.editLabelAction,
      hint: l.labelField,
      initial: row.label,
    );
    if (label == null) return;
    await widget.wallet.setAddressLabel(
      account: row.account,
      index: row.index,
      label: label,
    );
    setState(() => _addresses = widget.wallet.addresses());
  }

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

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final summary = widget.wallet.summary();

    return ValueListenableBuilder<SyncEvent?>(
      valueListenable: widget.registry.syncOf(summary.id),
      builder: (context, event, _) => ListView(
        padding: const EdgeInsets.all(KnSpace.lg),
        children: [
          Row(
            children: [
              Expanded(child: Text(summary.name, style: text.titleLarge)),
              WalletMenu(wallet: widget.wallet, registry: widget.registry),
            ],
          ),
          const SizedBox(height: KnSpace.xs),
          Text(
            [
              summary.mode.label(context),
              if (summary.viewOnly) l.viewOnlyTag,
            ].join(' · '),
            style: text.bodySmall,
          ),
          const SizedBox(height: KnSpace.lg),
          SyncPanel(
            wallet: widget.wallet,
            event: event,
            onRetry: () => widget.registry.startSync(summary.id),
            prices: summary.network.isTestNetwork()
                ? null
                : widget.registry.price,
          ),
          if (!summary.viewOnly) ...[
            const SizedBox(height: KnSpace.md),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton(onPressed: _send, child: Text(l.sendAction)),
            ),
          ],
          const SizedBox(height: KnSpace.xl),
          Text(l.historyTitle, style: text.titleMedium),
          const SizedBox(height: KnSpace.sm),
          const Divider(),
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
          const SizedBox(height: KnSpace.xl),
          Row(
            children: [
              Expanded(child: Text(l.receiveTitle, style: text.titleMedium)),
              TextButton(
                onPressed: _newAddress,
                child: Text(l.newAddressAction),
              ),
            ],
          ),
          const SizedBox(height: KnSpace.sm),
          const Divider(),
          for (final row in _addresses) ...[
            _AddressTile(row: row, onEditLabel: () => _editLabel(row)),
            const Divider(),
          ],
        ],
      ),
    );
  }
}

class _AddressTile extends StatelessWidget {
  const _AddressTile({required this.row, required this.onEditLabel});

  final AddressRow row;
  final VoidCallback onEditLabel;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final title = row.index == 0
        ? l.primaryAddressLabel
        : l.subaddressLabel(row.index);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: KnSpace.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  row.label.isEmpty ? title : '$title · ${row.label}',
                  style: text.labelLarge,
                ),
              ),
              IconButton(
                tooltip: l.editLabelAction,
                icon: const Icon(Icons.edit_outlined, size: 20),
                onPressed: onEditLabel,
              ),
              IconButton(
                tooltip: l.receiveQrAction,
                icon: const Icon(Icons.qr_code_2_outlined, size: 20),
                onPressed: () => _showQr(context, title, row.address),
              ),
              IconButton(
                tooltip: l.copyAction,
                icon: const Icon(Icons.copy_outlined, size: 20),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: row.address));
                  ScaffoldMessenger.of(context)
                    ..hideCurrentSnackBar()
                    ..showSnackBar(SnackBar(content: Text(l.copiedNotice)));
                },
              ),
            ],
          ),
          const SizedBox(height: KnSpace.xs),
          SelectableText(row.address, style: monoStyle(context, size: 13)),
        ],
      ),
    );
  }
}

/// The address as a `monero:` QR code, optionally asking for an amount.
/// Always dark on white, whatever the theme, because that is what scanners
/// read best.
void _showQr(BuildContext context, String title, String address) {
  showDialog<void>(
    context: context,
    builder: (_) => _ReceiveDialog(title: title, address: address),
  );
}

class _ReceiveDialog extends StatefulWidget {
  const _ReceiveDialog({required this.title, required this.address});

  final String title;
  final String address;

  @override
  State<_ReceiveDialog> createState() => _ReceiveDialogState();
}

class _ReceiveDialogState extends State<_ReceiveDialog> {
  final _amount = TextEditingController();

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final typed = _amount.text.trim();
    final amount = parseXmr(typed);
    final valid = typed.isEmpty || (amount != null && amount > BigInt.zero);
    final request = paymentRequestUri(
      widget.address,
      amount: typed.isEmpty || !valid ? null : amount,
    );
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 296,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ColoredBox(
                color: KnQr.paper,
                child: Padding(
                  // A quiet zone of about four modules, as scanners expect.
                  padding: const EdgeInsets.all(KnSpace.lg),
                  child: QrImageView(
                    data: request,
                    size: 248,
                    padding: EdgeInsets.zero,
                    backgroundColor: KnQr.paper,
                    eyeStyle: const QrEyeStyle(
                      eyeShape: QrEyeShape.square,
                      color: KnQr.ink,
                    ),
                    dataModuleStyle: const QrDataModuleStyle(
                      dataModuleShape: QrDataModuleShape.square,
                      color: KnQr.ink,
                    ),
                    semanticsLabel: request,
                  ),
                ),
              ),
              const SizedBox(height: KnSpace.md),
              SelectableText(
                widget.address,
                style: monoStyle(context, size: 12),
              ),
              const SizedBox(height: KnSpace.md),
              TextField(
                controller: _amount,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                style: monoStyle(context, size: 14),
                decoration: InputDecoration(
                  labelText: l.receiveAmountField,
                  suffixText: 'XMR',
                  errorText: valid ? null : l.sendAmountInvalid,
                ),
                onChanged: (_) => setState(() {}),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: request));
            ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(SnackBar(content: Text(l.copiedNotice)));
          },
          child: Text(l.receiveCopyRequestAction),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l.closeAction),
        ),
      ],
    );
  }
}
