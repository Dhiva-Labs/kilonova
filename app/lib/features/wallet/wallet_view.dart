import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../src/rust/api/wallets.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/mode_label.dart';
import '../wallets/wallet_registry.dart';
import 'wallet_dialogs.dart';

/// An unlocked wallet: its receiving addresses and wallet actions.
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

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final c = context.kn;
    final summary = widget.wallet.summary();

    return ListView(
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
        const SizedBox(height: KnSpace.md),
        Text(
          l.syncNotYet,
          style: text.bodyMedium!.copyWith(color: c.textSecondary),
        ),
        const SizedBox(height: KnSpace.lg),
        Row(
          children: [
            Expanded(child: Text(l.receiveTitle, style: text.titleMedium)),
            TextButton(onPressed: _newAddress, child: Text(l.newAddressAction)),
          ],
        ),
        const SizedBox(height: KnSpace.sm),
        const Divider(),
        for (final row in _addresses) ...[
          _AddressTile(row: row, onEditLabel: () => _editLabel(row)),
          const Divider(),
        ],
      ],
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
