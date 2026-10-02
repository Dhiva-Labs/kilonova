import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../platform/biometric_unlock.dart';
import '../../platform/secure_window.dart';
import '../../src/rust/api/send.dart';
import '../../src/rust/api/wallets.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/amount.dart';
import '../../widgets/error_line.dart';
import '../../widgets/password_fields.dart';
import '../book/address_book_screen.dart';
import '../wallets/wallet_registry.dart';
import 'monero_uri.dart';
import 'scan_qr.dart';

/// Most recipients one transaction can pay; matches the Rust core.
const _maxRecipients = 15;

/// Sending from an open wallet: fill in recipients, review what the signed
/// transaction will do, then confirm with the wallet password. Pops with
/// true once the transaction is published.
class SendScreen extends StatefulWidget {
  const SendScreen({super.key, required this.wallet, required this.registry});

  final OpenWallet wallet;
  final WalletRegistry registry;

  @override
  State<SendScreen> createState() => _SendScreenState();
}

class _Recipient {
  final address = TextEditingController();
  final amount = TextEditingController();
  String? addressError;
  String? amountError;

  void dispose() {
    address.dispose();
    amount.dispose();
  }
}

class _SendScreenState extends State<SendScreen> {
  final List<_Recipient> _recipients = [_Recipient()];
  bool _sweep = false;
  FeePriority _priority = FeePriority.normal;
  bool _busy = false;
  String? _error;
  String? _requestNote;
  PreparedSend? _prepared;

  @override
  void dispose() {
    for (final r in _recipients) {
      r.dispose();
    }
    super.dispose();
  }

  /// Fills the form from a `monero:` request typed or pasted into the
  /// address field of [recipient].
  bool _applyRequest(_Recipient recipient, String text) {
    final request = parsePaymentRequest(text);
    if (request == null || !text.trim().toLowerCase().startsWith('monero:')) {
      return false;
    }
    final payments = request.payments.take(_maxRecipients).toList();
    setState(() {
      final at = _recipients.indexOf(recipient);
      for (var i = 0; i < payments.length; i++) {
        if (at + i >= _recipients.length) _recipients.add(_Recipient());
        final r = _recipients[at + i];
        r.address.text = payments[i].address;
        final amount = payments[i].amount;
        if (amount != null) r.amount.text = formatXmr(amount);
      }
      if (_recipients.length > 1) _sweep = false;
      _requestNote = [
        request.recipientName,
        request.description,
      ].whereType<String>().join(' · ');
    });
    return true;
  }

  Future<void> _paste(_Recipient recipient) async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (text == null || !mounted) return;
    if (!_applyRequest(recipient, text)) {
      recipient.address.text = text.trim();
    }
  }

  Future<void> _pickContact(_Recipient recipient) async {
    final address = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => AddressBookScreen(wallet: widget.wallet, pick: true),
      ),
    );
    if (address == null || !mounted) return;
    setState(() {
      recipient.address.text = address;
      recipient.addressError = null;
    });
  }

  Future<void> _scan(_Recipient recipient) async {
    final l = AppLocalizations.of(context);
    final text = await scanQr(context);
    if (text == null || !mounted) return;
    final request = parsePaymentRequest(text);
    if (request == null) {
      setState(() => recipient.addressError = l.scanNotMonero);
      return;
    }
    if (!_applyRequest(recipient, text)) {
      setState(() {
        recipient.address.text = request.payments.first.address;
        recipient.addressError = null;
      });
    }
  }

  void _addRecipient() => setState(() {
    _recipients.add(_Recipient());
    _sweep = false;
  });

  void _removeRecipient(_Recipient recipient) => setState(() {
    _recipients.remove(recipient);
    recipient.dispose();
  });

  /// Checks the form; returns the payments, or null after marking errors.
  List<Payment>? _validate() {
    final l = AppLocalizations.of(context);
    final network = widget.wallet.summary().network;
    var ok = true;
    final payments = <Payment>[];
    for (final r in _recipients) {
      r.addressError = null;
      r.amountError = null;
      final address = r.address.text.trim();
      try {
        checkAddress(address: address, network: network);
      } on SendError {
        r.addressError = address.isEmpty
            ? l.sendAddressMissing
            : l.sendAddressInvalid;
        ok = false;
      }
      if (_sweep) continue;
      final amount = parseXmr(r.amount.text);
      if (amount == null || amount == BigInt.zero) {
        r.amountError = l.sendAmountInvalid;
        ok = false;
        continue;
      }
      payments.add(Payment(address: address, amount: amount));
    }
    setState(() {});
    return ok ? payments : null;
  }

  Future<void> _review() async {
    final payments = _validate();
    if (payments == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final prepared = await widget.wallet.prepareSend(
        payments: _sweep ? const [] : payments,
        sweepTo: _sweep ? _recipients.first.address.text.trim() : null,
        priority: _priority,
      );
      if (mounted) setState(() => _prepared = prepared);
    } on SendError catch (e) {
      if (mounted) setState(() => _error = sendErrorMessage(context, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _edit() {
    _prepared?.dispose();
    setState(() {
      _prepared = null;
      _error = null;
    });
  }

  void _sent() {
    final id = widget.wallet.summary().id;
    // Publishing pauses sync; it picks the spend up from here.
    widget.registry.startSync(id);
    Navigator.of(context).pop(true);
  }

  void _failed(String message) {
    widget.registry.startSync(widget.wallet.summary().id);
    _prepared?.dispose();
    setState(() {
      _prepared = null;
      _error = message;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final prepared = _prepared;
    return PopScope(
      canPop: !_busy,
      // Recipients and amounts stay out of screenshots and the app switcher.
      child: SecureWindow(
        child: Scaffold(
          appBar: AppBar(title: Text(l.sendTitle)),
          body: Align(
            alignment: Alignment.topLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: prepared == null
                  ? _form(context)
                  : _ConfirmView(
                      wallet: widget.wallet,
                      biometric: widget.registry.biometric,
                      prepared: prepared,
                      onEdit: _edit,
                      onSent: _sent,
                      onFailed: _failed,
                    ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _form(BuildContext context) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final balance = widget.wallet.balance();
    final note = _requestNote;
    return ListView(
      padding: const EdgeInsets.all(KnSpace.lg),
      children: [
        Text(
          l.spendableAmount(formatXmr(balance.unlocked)),
          style: monoStyle(context, size: 13, color: context.kn.textSecondary),
        ),
        if (note != null && note.isNotEmpty) ...[
          const SizedBox(height: KnSpace.sm),
          Text(l.sendRequestFrom(note), style: text.bodyMedium),
        ],
        const SizedBox(height: KnSpace.lg),
        for (final (i, r) in _recipients.indexed) ...[
          if (_recipients.length > 1)
            Row(
              children: [
                Expanded(
                  child: Text(
                    l.sendRecipientNumber(i + 1),
                    style: text.labelLarge,
                  ),
                ),
                TextButton(
                  onPressed: _busy ? null : () => _removeRecipient(r),
                  child: Text(l.sendRemoveRecipient),
                ),
              ],
            ),
          TextField(
            controller: r.address,
            enabled: !_busy,
            style: monoStyle(context, size: 13),
            minLines: 1,
            maxLines: 3,
            decoration: InputDecoration(
              labelText: l.sendAddressField,
              errorText: r.addressError,
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: l.bookChooseAction,
                    icon: const Icon(Icons.contacts_outlined, size: 20),
                    onPressed: _busy ? null : () => _pickContact(r),
                  ),
                  IconButton(
                    tooltip: scansWithCamera ? l.scanAction : l.scanImageAction,
                    icon: const Icon(Icons.qr_code_scanner, size: 20),
                    onPressed: _busy ? null : () => _scan(r),
                  ),
                  IconButton(
                    tooltip: l.pasteAction,
                    icon: const Icon(Icons.content_paste_outlined, size: 20),
                    onPressed: _busy ? null : () => _paste(r),
                  ),
                ],
              ),
            ),
            onChanged: (v) => _applyRequest(r, v),
          ),
          const SizedBox(height: KnSpace.sm),
          if (!_sweep)
            TextField(
              controller: r.amount,
              enabled: !_busy,
              style: monoStyle(context, size: 15),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: l.sendAmountField,
                suffixText: 'XMR',
                errorText: r.amountError,
              ),
            ),
          const SizedBox(height: KnSpace.md),
        ],
        Wrap(
          spacing: KnSpace.sm,
          children: [
            if (!_sweep && _recipients.length < _maxRecipients)
              TextButton(
                onPressed: _busy ? null : _addRecipient,
                child: Text(l.sendAddRecipient),
              ),
            if (_recipients.length == 1)
              TextButton(
                onPressed: _busy
                    ? null
                    : () => setState(() => _sweep = !_sweep),
                child: Text(_sweep ? l.sendEnterAmount : l.sendEverything),
              ),
          ],
        ),
        if (_sweep) ...[
          const SizedBox(height: KnSpace.sm),
          Text(l.sendEverythingNote, style: text.bodySmall),
        ],
        const SizedBox(height: KnSpace.lg),
        Text(l.sendFeeTitle, style: text.labelLarge),
        const SizedBox(height: KnSpace.sm),
        SegmentedButton<FeePriority>(
          segments: [
            ButtonSegment(value: FeePriority.low, label: Text(l.feeLow)),
            ButtonSegment(value: FeePriority.normal, label: Text(l.feeNormal)),
            ButtonSegment(value: FeePriority.high, label: Text(l.feeHigh)),
            ButtonSegment(value: FeePriority.urgent, label: Text(l.feeUrgent)),
          ],
          selected: {_priority},
          showSelectedIcon: false,
          onSelectionChanged: _busy
              ? null
              : (s) => setState(() => _priority = s.single),
        ),
        const SizedBox(height: KnSpace.xs),
        Text(l.sendFeeHelp, style: text.bodySmall),
        if (_error != null) ...[
          const SizedBox(height: KnSpace.md),
          ErrorLine(_error!),
        ],
        const SizedBox(height: KnSpace.lg),
        Row(
          children: [
            FilledButton(
              onPressed: _busy ? null : _review,
              child: Text(l.sendReviewAction),
            ),
            if (_busy) ...[
              const SizedBox(width: KnSpace.md),
              Expanded(child: Text(l.sendPreparing, style: text.bodySmall)),
            ],
          ],
        ),
      ],
    );
  }
}

/// What the signed transaction will do, and the password check that
/// publishes it.
class _ConfirmView extends StatefulWidget {
  const _ConfirmView({
    required this.wallet,
    required this.biometric,
    required this.prepared,
    required this.onEdit,
    required this.onSent,
    required this.onFailed,
  });

  final OpenWallet wallet;
  final BiometricUnlock biometric;
  final PreparedSend prepared;
  final VoidCallback onEdit;
  final VoidCallback onSent;
  final ValueChanged<String> onFailed;

  @override
  State<_ConfirmView> createState() => _ConfirmViewState();
}

class _ConfirmViewState extends State<_ConfirmView> {
  final _password = TextEditingController();
  bool _busy = false;
  bool _biometric = false;
  String? _passwordError;

  @override
  void initState() {
    super.initState();
    widget.biometric.isEnabled(widget.wallet.summary().id).then((on) {
      if (mounted) setState(() => _biometric = on);
    });
  }

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _passwordError = null;
    });
    try {
      await widget.wallet.confirmSend(
        send: widget.prepared,
        password: _password.text,
      );
      _password.clear();
      widget.onSent();
    } on SendError catch (e) {
      _password.clear();
      if (!mounted) return;
      if (e == SendError.wrongPassword) {
        setState(
          () =>
              _passwordError = AppLocalizations.of(context).errorWrongPassword,
        );
      } else {
        widget.onFailed(sendErrorMessage(context, e));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendWithBiometric() async {
    final l = AppLocalizations.of(context);
    final summary = widget.wallet.summary();
    try {
      _password.text = await widget.biometric.unlock(
        summary.id,
        title: l.biometricSendTitle(summary.name),
        cancel: l.cancelAction,
      );
      await _send();
    } on BiometricException catch (e) {
      if (!mounted || e.failure == BiometricFailure.cancelled) return;
      setState(() {
        _passwordError = e.failure == BiometricFailure.invalidated
            ? l.biometricInvalidated
            : l.biometricFailed;
        _biometric = e.failure != BiometricFailure.invalidated;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final s = widget.prepared.summary();
    final paid = s.payments.fold(BigInt.zero, (sum, p) => sum + p.amount);
    final network = widget.wallet.summary().network;

    return ListView(
      padding: const EdgeInsets.all(KnSpace.lg),
      children: [
        Text(l.sendConfirmTitle, style: text.titleMedium),
        if (network.isTestNetwork()) ...[
          const SizedBox(height: KnSpace.xs),
          Text(l.sendTestNetworkNote, style: text.bodySmall),
        ],
        const SizedBox(height: KnSpace.md),
        const Divider(),
        for (final p in s.payments) ...[
          const SizedBox(height: KnSpace.sm),
          AmountText(p.amount, size: 18),
          const SizedBox(height: KnSpace.xs),
          SelectableText(
            p.address,
            style: monoStyle(
              context,
              size: 12,
              color: context.kn.textSecondary,
            ),
          ),
          const SizedBox(height: KnSpace.sm),
          const Divider(),
        ],
        _Line(label: l.sendFeeLine, amount: s.fee),
        _Line(label: l.sendTotalLine, amount: paid + s.fee, strong: true),
        if (s.change > BigInt.zero)
          _Line(label: l.sendChangeLine, amount: s.change),
        const SizedBox(height: KnSpace.sm),
        Text(l.sendViaLine(_host(s.via)), style: text.bodySmall),
        const SizedBox(height: KnSpace.lg),
        PasswordField(
          controller: _password,
          autofocus: true,
          errorText: _passwordError,
          onSubmitted: (_) => _send(),
        ),
        const SizedBox(height: KnSpace.md),
        Wrap(
          spacing: KnSpace.sm,
          runSpacing: KnSpace.sm,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton(
              onPressed: _busy ? null : _send,
              child: Text(l.sendConfirmAction),
            ),
            if (_biometric)
              TextButton(
                onPressed: _busy ? null : _sendWithBiometric,
                child: Text(l.biometricSendAction),
              ),
            TextButton(
              onPressed: _busy ? null : widget.onEdit,
              child: Text(l.sendEditAction),
            ),
            if (_busy) Text(l.sendPublishing, style: text.bodySmall),
          ],
        ),
      ],
    );
  }

  static String _host(String url) => Uri.tryParse(url)?.host ?? url;
}

class _Line extends StatelessWidget {
  const _Line({required this.label, required this.amount, this.strong = false});

  final String label;
  final BigInt amount;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: KnSpace.xs),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: strong ? text.labelLarge : text.bodyMedium,
            ),
          ),
          AmountText(amount, size: strong ? 16 : 14),
        ],
      ),
    );
  }
}

String sendErrorMessage(BuildContext context, SendError e) {
  final l = AppLocalizations.of(context);
  return switch (e) {
    SendError.badAddress => l.sendAddressInvalid,
    SendError.zeroAmount => l.sendAmountInvalid,
    SendError.tooManyPayments => l.sendTooManyPayments,
    SendError.insufficientFunds => l.sendInsufficientFunds,
    SendError.tooManyInputs => l.sendTooManyInputs,
    SendError.viewOnly => l.sendViewOnly,
    SendError.notSynced => l.sendNotSynced,
    SendError.unreachable => l.sendUnreachable,
    SendError.rejected => l.sendRejected,
    SendError.build => l.sendBuildFailed,
    SendError.lwsServerNotSet => l.syncLwsServerNotSet,
    SendError.lwsConsentNeeded => l.sendLwsConsentNeeded,
    SendError.wrongPassword => l.errorWrongPassword,
    SendError.alreadyUsed => l.sendAlreadyUsed,
    SendError.locked || SendError.storage => l.sendBuildFailed,
  };
}
