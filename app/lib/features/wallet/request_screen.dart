import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../src/rust/api/requests.dart';
import '../../src/rust/api/wallets.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/amount.dart';
import '../../widgets/kn_button.dart';
import '../../widgets/kn_card.dart';
import '../../widgets/kn_field.dart';
import '../../widgets/kn_segments.dart';
import '../../widgets/kn_sheet.dart';
import '../../widgets/wallet_error_text.dart';

/// The status line for a request, worded as the wallet page and the
/// request screen both show it.
String requestStatusText(BuildContext context, RequestRow row) {
  final l = AppLocalizations.of(context);
  return switch (row.status) {
    RequestStatus.waiting => l.requestStatusWaiting,
    RequestStatus.arriving => l.requestStatusArriving,
    RequestStatus.partial => l.requestStatusPartial(
      formatXmr(row.received),
      formatXmr(row.amount),
    ),
    RequestStatus.paid => l.requestStatusPaid,
    RequestStatus.expired => l.requestStatusExpired,
  };
}

enum _Expiry { none, day, week }

/// Asks for an amount, a note and an expiry, then creates the request.
/// Returns the new request, or null if cancelled.
Future<RequestRow?> showRequestDialog(BuildContext context, OpenWallet wallet) {
  final l = AppLocalizations.of(context);
  final key = GlobalKey<_RequestDialogState>();
  return showKnDialog<RequestRow>(
    context,
    _RequestDialog(key: key, wallet: wallet),
    title: l.requestDialogTitle,
    actions: [
      Builder(
        builder: (innerContext) => KnButton.text(
          l.cancelAction,
          onPressed: () => Navigator.of(innerContext).pop(),
        ),
      ),
      KnButton.primary(
        l.requestCreateAction,
        onPressed: () => key.currentState?._create(),
      ),
    ],
  );
}

class _RequestDialog extends StatefulWidget {
  const _RequestDialog({super.key, required this.wallet});

  final OpenWallet wallet;

  @override
  State<_RequestDialog> createState() => _RequestDialogState();
}

class _RequestDialogState extends State<_RequestDialog> {
  final _amount = TextEditingController();
  final _for = TextEditingController();
  var _expiry = _Expiry.none;
  String? _amountError;

  @override
  void dispose() {
    _amount.dispose();
    _for.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final l = AppLocalizations.of(context);
    final amount = parseXmr(_amount.text);
    if (amount == null || amount == BigInt.zero) {
      setState(() => _amountError = l.sendAmountInvalid);
      return;
    }
    setState(() => _amountError = null);
    final hours = switch (_expiry) {
      _Expiry.none => null,
      _Expiry.day => 24,
      _Expiry.week => 24 * 7,
    };
    try {
      final row = await widget.wallet.createRequest(
        amount: amount,
        label: _for.text.trim(),
        expiresInHours: hours,
      );
      if (mounted) Navigator.of(context).pop(row);
    } on WalletError catch (e) {
      if (mounted) {
        setState(() => _amountError = walletErrorMessage(context, e));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        KnField(
          controller: _amount,
          label: l.requestAmountField,
          suffix: 'XMR',
          mono: true,
          autofocus: true,
          error: _amountError,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
        ),
        const SizedBox(height: KnSpace.md),
        KnField(controller: _for, label: l.requestForField),
        const SizedBox(height: KnSpace.md),
        KnSegments<_Expiry>(
          segments: [
            KnSegment(_Expiry.none, l.requestExpiryNone),
            KnSegment(_Expiry.day, l.requestExpiry1Day),
            KnSegment(_Expiry.week, l.requestExpiry7Days),
          ],
          selected: _expiry,
          onChanged: (v) => setState(() => _expiry = v),
        ),
      ],
    );
  }
}

/// Creates a request through [showRequestDialog] and opens it. Returns
/// without doing anything if the dialog is cancelled.
Future<void> openRequestDialog(BuildContext context, OpenWallet wallet) async {
  final created = await showRequestDialog(context, wallet);
  if (created == null || !context.mounted) return;
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => RequestScreen(wallet: wallet, request: created),
    ),
  );
}

/// One payment request: its QR, amount, status and address, with actions
/// to copy the link or delete it.
class RequestScreen extends StatefulWidget {
  const RequestScreen({super.key, required this.wallet, required this.request});

  final OpenWallet wallet;
  final RequestRow request;

  @override
  State<RequestScreen> createState() => _RequestScreenState();
}

class _RequestScreenState extends State<RequestScreen> {
  late final RequestRow _row = widget.request;

  void _copy(String text) {
    final l = AppLocalizations.of(context);
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(l.copiedNotice)));
  }

  Future<void> _delete() async {
    await widget.wallet.deleteRequest(id: _row.id);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final c = context.kn;
    final row = _row;
    final label = row.label.isEmpty ? l.requestDefaultLabel : row.label;

    return Scaffold(
      appBar: AppBar(title: Text(label)),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: ListView(
              padding: const EdgeInsets.all(KnSpace.lg),
              children: [
                KnCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: ColoredBox(
                          color: KnQr.paper,
                          child: Padding(
                            padding: const EdgeInsets.all(KnSpace.lg),
                            child: QrImageView(
                              data: row.uri,
                              size: 220,
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
                              semanticsLabel: row.uri,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: KnSpace.md),
                      AmountText(row.amount, size: text.titleLarge!.fontSize),
                      const SizedBox(height: KnSpace.xs),
                      Text(label, style: text.bodyMedium),
                      const SizedBox(height: KnSpace.xs),
                      Text(
                        requestStatusText(context, row),
                        style: text.bodyMedium!.copyWith(
                          color: row.status == RequestStatus.paid
                              ? c.received
                              : null,
                        ),
                      ),
                      const SizedBox(height: KnSpace.md),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: SelectableText(
                              row.address,
                              style: monoStyle(context, size: 13),
                            ),
                          ),
                          const SizedBox(width: KnSpace.sm),
                          KnIconButton(
                            icon: const Icon(Icons.copy_outlined),
                            tooltip: l.copyAction,
                            onPressed: () => _copy(row.address),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: KnSpace.md),
                Align(
                  alignment: Alignment.centerLeft,
                  child: KnButton.text(
                    l.requestCopyLinkAction,
                    onPressed: () => _copy(row.uri),
                  ),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: KnButton.text(
                    l.requestDeleteAction,
                    onPressed: _delete,
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
