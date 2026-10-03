import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../src/rust/api/wallets.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/amount.dart';
import '../../widgets/kn_button.dart';
import '../../widgets/kn_card.dart';
import '../../widgets/kn_field.dart';
import '../../widgets/kn_sheet.dart';
import '../send/monero_uri.dart';
import 'request_screen.dart';
import 'wallet_dialogs.dart';

/// Opens the receive screen: a dialog on desktop, a full screen on phone.
Future<void> openReceiveScreen(
  BuildContext context, {
  required OpenWallet wallet,
}) {
  if (context.isPhoneWidth) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => ReceiveScreen(wallet: wallet)),
    );
  }
  return showKnDialog<void>(
    context,
    ReceiveScreen(wallet: wallet, embedded: true),
    title: AppLocalizations.of(context).receiveTitle,
    width: 520,
  );
}

/// The chosen address as a QR code, with an optional amount, and the list
/// of addresses to choose from.
class ReceiveScreen extends StatefulWidget {
  const ReceiveScreen({super.key, required this.wallet, this.embedded = false});

  final OpenWallet wallet;

  /// True when shown inside [showKnDialog]; false renders its own
  /// [Scaffold] for a full phone screen.
  final bool embedded;

  @override
  State<ReceiveScreen> createState() => _ReceiveScreenState();
}

class _ReceiveScreenState extends State<ReceiveScreen> {
  late List<AddressRow> _addresses = widget.wallet.addresses();
  int _selected = 0;
  final _amount = TextEditingController();

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _newAddress() async {
    final l = AppLocalizations.of(context);
    final label = await askForText(
      context,
      title: l.newAddressAction,
      hint: l.newAddressLabelHint,
    );
    if (label == null) return;
    await widget.wallet.newAddress(label: label);
    setState(() {
      _addresses = widget.wallet.addresses();
      _selected = _addresses.length - 1;
    });
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

  void _copy(String text) {
    final l = AppLocalizations.of(context);
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(l.copiedNotice)));
  }

  String _title(BuildContext context, AddressRow row) {
    final l = AppLocalizations.of(context);
    return row.index == 0
        ? l.primaryAddressLabel
        : l.subaddressLabel(row.index);
  }

  static String _shorten(String address) => address.length > 24
      ? '${address.substring(0, 12)}…${address.substring(address.length - 12)}'
      : address;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final row = _addresses[_selected];
    final typed = _amount.text.trim();
    final amount = parseXmr(typed);
    final valid = typed.isEmpty || (amount != null && amount > BigInt.zero);
    final request = paymentRequestUri(
      row.address,
      amount: typed.isEmpty || !valid ? null : amount,
    );

    final qrBlock = ColoredBox(
      color: KnQr.paper,
      child: Padding(
        // A quiet zone of about four modules, as scanners expect.
        padding: const EdgeInsets.all(KnSpace.lg),
        child: Center(
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
    );

    final addressLine = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: Text(row.address, style: monoStyle(context, size: 13))),
        const SizedBox(width: KnSpace.sm),
        KnIconButton(
          icon: const Icon(Icons.copy_outlined),
          tooltip: l.copyAction,
          onPressed: () => _copy(row.address),
        ),
      ],
    );

    // Desktop shows the QR and address on the `surface` card background;
    // the phone screen keeps its existing plain layout.
    final qrSection = widget.embedded
        ? KnCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(child: qrBlock),
                const SizedBox(height: KnSpace.md),
                addressLine,
              ],
            ),
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              qrBlock,
              const SizedBox(height: KnSpace.md),
              addressLine,
            ],
          );

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        qrSection,
        const SizedBox(height: KnSpace.md),
        KnField(
          controller: _amount,
          label: l.receiveAmountField,
          suffix: 'XMR',
          mono: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          error: valid ? null : l.sendAmountInvalid,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: KnSpace.sm),
        Align(
          alignment: Alignment.centerLeft,
          child: KnButton.text(
            l.receiveCopyRequestAction,
            onPressed: () => _copy(request),
          ),
        ),
        const SizedBox(height: KnSpace.sm),
        KnButton.secondary(
          l.requestAction,
          onPressed: () => openRequestDialog(context, widget.wallet),
        ),
        const SizedBox(height: KnSpace.lg),
        Eyebrow(l.addressesTitle),
        const SizedBox(height: KnSpace.sm),
        KnCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: withDividers([
              for (final (i, a) in _addresses.indexed)
                KnRow(
                  selected: i == _selected,
                  title: Text(a.label.isEmpty ? _title(context, a) : a.label),
                  subtitle: Text(
                    _shorten(a.address),
                    style: monoStyle(context, size: 13),
                  ),
                  trailing: KnIconButton(
                    icon: const Icon(Icons.edit_outlined),
                    tooltip: l.editLabelAction,
                    onPressed: () => _editLabel(a),
                  ),
                  onTap: () => setState(() => _selected = i),
                ),
            ]),
          ),
        ),
        const SizedBox(height: KnSpace.md),
        Align(
          alignment: Alignment.centerLeft,
          child: KnButton.text(l.newAddressAction, onPressed: _newAddress),
        ),
      ],
    );

    if (widget.embedded) return content;
    return Scaffold(
      appBar: AppBar(title: Text(l.receiveTitle)),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(KnSpace.lg),
          child: content,
        ),
      ),
    );
  }
}
