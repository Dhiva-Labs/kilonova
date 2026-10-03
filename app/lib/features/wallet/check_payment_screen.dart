import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../src/rust/api/proof.dart';
import '../../src/rust/api/wallets.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/amount.dart';
import '../../widgets/copy_value.dart';
import '../../widgets/error_line.dart';
import '../../widgets/kn_button.dart';
import '../../widgets/kn_card.dart';
import '../../widgets/kn_field.dart';

String _proofFailureMessage(BuildContext context, ProofFailure failure) {
  final l = AppLocalizations.of(context);
  return switch (failure) {
    ProofFailure.badAddress => l.errorBadAddress,
    ProofFailure.badTransactionId => l.proofErrorBadTransactionId,
    ProofFailure.badKey => l.proofErrorBadKey,
    ProofFailure.unknownTransaction => l.proofErrorUnknownTransaction,
    ProofFailure.keyMismatch => l.proofErrorKeyMismatch,
    ProofFailure.unreachable => l.proofErrorUnreachable,
  };
}

/// Checks what an address received in a transaction, from the transaction
/// id and key the sender shared.
class CheckPaymentScreen extends StatefulWidget {
  const CheckPaymentScreen({super.key, required this.wallet});

  final OpenWallet wallet;

  @override
  State<CheckPaymentScreen> createState() => _CheckPaymentScreenState();
}

class _CheckPaymentScreenState extends State<CheckPaymentScreen> {
  final _txId = TextEditingController();
  final _txKey = TextEditingController();
  late final _address = TextEditingController(
    text: widget.wallet.addresses().first.address,
  );
  bool _busy = false;
  String? _idError;
  String? _keyError;
  String? _addressError;
  String? _error;
  PaymentCheck? _result;

  @override
  void dispose() {
    _txId.dispose();
    _txKey.dispose();
    _address.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    setState(() {
      _busy = true;
      _idError = null;
      _keyError = null;
      _addressError = null;
      _error = null;
      _result = null;
    });
    try {
      final result = await checkPayment(
        network: widget.wallet.summary().network,
        txId: _txId.text.trim(),
        txKey: _txKey.text.trim(),
        address: _address.text.trim(),
      );
      if (mounted) setState(() => _result = result);
    } on ProofFailure catch (e) {
      if (!mounted) return;
      setState(() {
        switch (e) {
          case ProofFailure.badTransactionId:
            _idError = _proofFailureMessage(context, e);
          case ProofFailure.badKey:
            _keyError = _proofFailureMessage(context, e);
          case ProofFailure.badAddress:
            _addressError = _proofFailureMessage(context, e);
          case ProofFailure.unknownTransaction:
          case ProofFailure.keyMismatch:
          case ProofFailure.unreachable:
            _error = _proofFailureMessage(context, e);
        }
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _status(BuildContext context, PaymentCheck result) {
    final l = AppLocalizations.of(context);
    if (result.received == BigInt.zero) return l.checkPaymentNothing;
    if (result.inPool) return l.checkPaymentWaitingPool;
    return l.checkPaymentInBlocks(result.confirmations.toInt());
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final phone = context.isPhoneWidth;
    final result = _result;

    return Scaffold(
      appBar: AppBar(title: Text(l.checkPaymentAction)),
      body: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: EdgeInsets.all(phone ? KnSpace.md : KnSpace.xl),
            children: [
              Text(l.checkPaymentExplain, style: text.bodyMedium),
              const SizedBox(height: KnSpace.lg),
              KnField(
                controller: _txId,
                label: l.checkPaymentTxIdField,
                mono: true,
                enabled: !_busy,
                error: _idError,
                trailing: [PasteButton(controller: _txId)],
              ),
              const SizedBox(height: KnSpace.md),
              KnField(
                controller: _txKey,
                label: l.checkPaymentTxKeyField,
                mono: true,
                multiline: true,
                enabled: !_busy,
                error: _keyError,
                trailing: [PasteButton(controller: _txKey)],
              ),
              const SizedBox(height: KnSpace.md),
              KnField(
                controller: _address,
                label: l.checkPaymentAddressField,
                mono: true,
                multiline: true,
                enabled: !_busy,
                error: _addressError,
                trailing: [PasteButton(controller: _address)],
              ),
              const SizedBox(height: KnSpace.lg),
              KnButton.primary(
                l.checkPaymentCheckAction,
                onPressed: _busy ? null : _check,
              ),
              if (_error != null) ...[
                const SizedBox(height: KnSpace.md),
                ErrorLine(_error!),
              ],
              if (result != null) ...[
                const SizedBox(height: KnSpace.lg),
                KnCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          AmountText(result.received),
                          const SizedBox(width: KnSpace.xs),
                          Padding(
                            padding: const EdgeInsets.only(bottom: 2),
                            child: Text(
                              l.checkPaymentReceivedSuffix,
                              style: text.bodySmall,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: KnSpace.xs),
                      Text(_status(context, result), style: text.bodyMedium),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
