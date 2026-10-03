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
import '../../widgets/kn_button.dart';
import '../../widgets/kn_card.dart';
import '../../widgets/kn_field.dart';
import '../../widgets/kn_icons.dart';
import '../../widgets/kn_segments.dart';
import '../../widgets/password_fields.dart';
import '../book/address_book_screen.dart';
import '../cold/animated_qr.dart';
import '../cold/cold_failure_text.dart';
import '../../src/rust/api/cold.dart';
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
  ColdSend? _coldPrepared;

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

  bool get _coldFlow => widget.wallet.summary().viewOnly;

  Future<void> _review() async {
    final payments = _validate();
    if (payments == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_coldFlow) {
        final prepared = await widget.wallet.prepareColdSend(
          payments: _sweep ? const [] : payments,
          sweepTo: _sweep ? _recipients.first.address.text.trim() : null,
          priority: _priority,
        );
        if (mounted) setState(() => _coldPrepared = prepared);
      } else {
        final prepared = await widget.wallet.prepareSend(
          payments: _sweep ? const [] : payments,
          sweepTo: _sweep ? _recipients.first.address.text.trim() : null,
          priority: _priority,
        );
        if (mounted) setState(() => _prepared = prepared);
      }
    } on SendError catch (e) {
      if (mounted) setState(() => _error = sendErrorMessage(context, e));
    } on ColdFailure catch (e) {
      if (mounted) setState(() => _error = coldFailureMessage(context, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _edit() {
    _prepared?.dispose();
    setState(() {
      _prepared = null;
      _coldPrepared = null;
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
      _coldPrepared = null;
      _error = message;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final prepared = _prepared;
    final coldPrepared = _coldPrepared;
    final isPhone = context.isPhoneWidth;
    final Widget body;
    if (coldPrepared != null) {
      body = _ColdConfirmView(
        wallet: widget.wallet,
        registry: widget.registry,
        coldSend: coldPrepared,
        onEdit: _edit,
        onSent: _sent,
        onFailed: _failed,
      );
    } else if (prepared != null) {
      body = _ConfirmView(
        wallet: widget.wallet,
        biometric: widget.registry.biometric,
        prepared: prepared,
        onEdit: _edit,
        onSent: _sent,
        onFailed: _failed,
      );
    } else {
      body = _form(context);
    }
    return PopScope(
      canPop: !_busy,
      // Recipients and amounts stay out of screenshots and the app switcher.
      child: SecureWindow(
        child: Scaffold(
          appBar: isPhone ? AppBar(title: Text(l.sendTitle)) : null,
          body: SafeArea(
            child: Align(
              alignment: Alignment.topLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: body,
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
    final c = context.kn;
    final isPhone = context.isPhoneWidth;
    final balance = widget.wallet.balance();
    final note = _requestNote;
    final pad = isPhone ? KnSpace.md : KnSpace.xl;

    final content = ListView(
      padding: EdgeInsets.fromLTRB(pad, pad, pad, pad),
      children: [
        if (!isPhone) ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(child: Text(l.sendTitle, style: text.headlineSmall)),
              KnButton.text(
                l.cancelAction,
                onPressed: _busy ? null : () => Navigator.of(context).pop(),
              ),
            ],
          ),
          const SizedBox(height: KnSpace.lg),
        ],
        Text(
          l.spendableAmount(formatXmrShort(balance.unlocked)),
          style: monoStyle(context, size: 13, color: c.textSecondary),
        ),
        if (note != null && note.isNotEmpty) ...[
          const SizedBox(height: KnSpace.sm),
          Text(l.sendRequestFrom(note), style: text.bodyMedium),
        ],
        const SizedBox(height: KnSpace.lg),
        for (final (i, r) in _recipients.indexed) ...[
          if (_recipients.length > 1) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(child: Eyebrow(l.sendRecipientNumber(i + 1))),
                KnButton.text(
                  l.sendRemoveRecipient,
                  onPressed: _busy ? null : () => _removeRecipient(r),
                ),
              ],
            ),
            const SizedBox(height: KnSpace.sm),
          ],
          KnField(
            controller: r.address,
            label: l.sendAddressField,
            hint: l.sendAddressHint,
            mono: true,
            multiline: true,
            enabled: !_busy,
            error: r.addressError,
            onChanged: (v) => _applyRequest(r, v),
            trailing: [
              KnIconButton(
                icon: const KnIcon(KnIcons.contacts),
                tooltip: l.bookChooseAction,
                onPressed: _busy ? null : () => _pickContact(r),
              ),
              KnIconButton(
                icon: const KnIcon(KnIcons.scan),
                tooltip: scansWithCamera ? l.scanAction : l.scanImageAction,
                onPressed: _busy ? null : () => _scan(r),
              ),
              KnIconButton(
                icon: const KnIcon(KnIcons.paste),
                tooltip: l.pasteAction,
                onPressed: _busy ? null : () => _paste(r),
              ),
            ],
          ),
          const SizedBox(height: KnSpace.sm),
          if (!_sweep)
            KnField(
              controller: r.amount,
              label: l.sendAmountField,
              suffix: 'XMR',
              mono: true,
              enabled: !_busy,
              error: r.amountError,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
            ),
          if (_recipients.length == 1)
            Padding(
              padding: const EdgeInsets.only(top: KnSpace.xs),
              child: Align(
                alignment: Alignment.centerRight,
                child: KnButton.text(
                  _sweep ? l.sendEnterAmount : l.sendEverything,
                  onPressed: _busy
                      ? null
                      : () => setState(() => _sweep = !_sweep),
                ),
              ),
            ),
          if (_sweep) ...[
            const SizedBox(height: KnSpace.xs),
            Text(l.sendEverythingNote, style: text.bodySmall),
          ],
          const SizedBox(height: KnSpace.md),
        ],
        if (!_sweep && _recipients.length < _maxRecipients)
          Align(
            alignment: Alignment.centerLeft,
            child: KnButton.text(
              l.sendAddRecipient,
              onPressed: _busy ? null : _addRecipient,
            ),
          ),
        const SizedBox(height: KnSpace.lg),
        Eyebrow(l.sendFeeTitle),
        const SizedBox(height: KnSpace.sm),
        KnSegments<FeePriority>(
          segments: [
            KnSegment(FeePriority.low, l.feeLow),
            KnSegment(FeePriority.normal, l.feeNormal),
            KnSegment(FeePriority.high, l.feeHigh),
            KnSegment(FeePriority.urgent, l.feeUrgent),
          ],
          selected: _priority,
          expand: true,
          onChanged: _busy ? null : (v) => setState(() => _priority = v),
        ),
        const SizedBox(height: KnSpace.xs),
        Text(l.sendFeeHelp, style: text.bodySmall),
        if (_error != null) ...[
          const SizedBox(height: KnSpace.md),
          ErrorLine(_error!),
        ],
        if (!isPhone) ...[
          const SizedBox(height: KnSpace.lg),
          Row(
            children: [
              KnButton.primary(
                l.sendReviewAction,
                onPressed: _busy ? null : _review,
              ),
              if (_busy) ...[
                const SizedBox(width: KnSpace.md),
                Expanded(child: Text(l.sendPreparing, style: text.bodySmall)),
              ],
            ],
          ),
        ],
      ],
    );

    if (!isPhone) return content;

    return Column(
      children: [
        Expanded(child: content),
        Container(
          padding: const EdgeInsets.all(KnSpace.md),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: c.border)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_busy) ...[
                Text(l.sendPreparing, style: text.bodySmall),
                const SizedBox(height: KnSpace.sm),
              ],
              KnButton.primary(
                l.sendReviewAction,
                onPressed: _busy ? null : _review,
                expand: true,
              ),
            ],
          ),
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
    final c = context.kn;
    final isPhone = context.isPhoneWidth;
    final s = widget.prepared.summary();
    final paid = s.payments.fold(BigInt.zero, (sum, p) => sum + p.amount);
    final network = widget.wallet.summary().network;
    final highFee = s.fee * BigInt.from(20) > paid;
    final contacts = {
      for (final contact in widget.wallet.contacts())
        contact.address: contact.name,
    };
    final pad = isPhone ? KnSpace.md : KnSpace.xl;

    final content = ListView(
      padding: EdgeInsets.fromLTRB(pad, pad, pad, pad),
      children: [
        Text(
          l.sendConfirmTitle,
          style: isPhone ? text.titleLarge : text.headlineSmall,
        ),
        const SizedBox(height: KnSpace.xs),
        Text(
          network.isTestNetwork() ? l.sendTestNetworkNote : l.aboutUnaudited,
          style: text.bodySmall,
        ),
        const SizedBox(height: KnSpace.lg),
        KnCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Eyebrow(l.sendSendingLabel),
              const SizedBox(height: KnSpace.md),
              for (final p in s.payments) ...[
                if (contacts[p.address] != null) ...[
                  Text(contacts[p.address]!, style: text.bodyMedium),
                  const SizedBox(height: 2),
                ],
                AmountText(p.amount, size: text.titleLarge!.fontSize),
                const SizedBox(height: 2),
                Text(
                  p.address,
                  style: monoStyle(context, size: 13, color: c.textSecondary),
                ),
                const SizedBox(height: KnSpace.md),
              ],
              if (highFee) ...[
                ErrorLine(l.sendHighFeeWarning),
                const SizedBox(height: KnSpace.sm),
              ],
              ...withDividers([
                KeyValue(label: l.sendFeeLine, value: AmountText(s.fee)),
                KeyValue(
                  label: l.sendTotalLine,
                  value: AmountText(paid + s.fee),
                  strong: true,
                ),
                if (s.change > BigInt.zero)
                  KeyValue(
                    label: l.sendChangeLine,
                    value: AmountText(s.change),
                  ),
              ]),
              const SizedBox(height: KnSpace.sm),
              Text(l.sendViaLine(_host(s.via)), style: text.bodySmall),
            ],
          ),
        ),
        const SizedBox(height: KnSpace.lg),
        PasswordField(
          controller: _password,
          autofocus: true,
          errorText: _passwordError,
          onSubmitted: (_) => _send(),
        ),
        const SizedBox(height: KnSpace.md),
        if (!isPhone)
          Wrap(
            spacing: KnSpace.sm,
            runSpacing: KnSpace.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              KnButton.primary(
                l.sendConfirmAction,
                onPressed: _busy ? null : _send,
              ),
              KnButton.text(
                l.sendEditAction,
                onPressed: _busy ? null : widget.onEdit,
              ),
              if (_biometric)
                KnButton.text(
                  l.biometricSendAction,
                  onPressed: _busy ? null : _sendWithBiometric,
                ),
              if (_busy) Text(l.sendPublishing, style: text.bodySmall),
            ],
          )
        else ...[
          if (_biometric)
            Padding(
              padding: const EdgeInsets.only(bottom: KnSpace.sm),
              child: Align(
                alignment: Alignment.centerLeft,
                child: KnButton.text(
                  l.biometricSendAction,
                  onPressed: _busy ? null : _sendWithBiometric,
                ),
              ),
            ),
          if (_busy)
            Padding(
              padding: const EdgeInsets.only(bottom: KnSpace.sm),
              child: Text(l.sendPublishing, style: text.bodySmall),
            ),
        ],
      ],
    );

    if (!isPhone) return content;

    return Column(
      children: [
        Expanded(child: content),
        Container(
          padding: const EdgeInsets.all(KnSpace.md),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: c.border)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              KnButton.primary(
                l.sendConfirmAction,
                onPressed: _busy ? null : _send,
                expand: true,
              ),
              const SizedBox(height: KnSpace.sm),
              KnButton.text(
                l.sendEditAction,
                onPressed: _busy ? null : widget.onEdit,
              ),
            ],
          ),
        ),
      ],
    );
  }

  static String _host(String url) => Uri.tryParse(url)?.host ?? url;
}

/// What a cold-signed send will do, and the scan step that relays the
/// signed transaction back from the offline wallet.
class _ColdConfirmView extends StatefulWidget {
  const _ColdConfirmView({
    required this.wallet,
    required this.registry,
    required this.coldSend,
    required this.onEdit,
    required this.onSent,
    required this.onFailed,
  });

  final OpenWallet wallet;
  final WalletRegistry registry;
  final ColdSend coldSend;
  final VoidCallback onEdit;
  final VoidCallback onSent;
  final ValueChanged<String> onFailed;

  @override
  State<_ColdConfirmView> createState() => _ColdConfirmViewState();
}

class _ColdConfirmViewState extends State<_ColdConfirmView> {
  late final ColdMessage _message = widget.coldSend.message();
  bool _busy = false;

  Future<void> _scanSigned() async {
    final l = AppLocalizations.of(context);
    setState(() => _busy = true);
    final bytes = await widget.registry.cold.receive(
      context,
      title: l.coldScanSignedAction,
    );
    if (bytes == null) {
      if (mounted) setState(() => _busy = false);
      return;
    }
    try {
      await widget.wallet.importColdAnswer(
        message: bytes,
        destinations: widget.coldSend.summary().payments,
      );
      widget.registry.startSync(widget.wallet.summary().id);
      widget.onSent();
    } on ColdFailure catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      widget.onFailed(coldFailureMessage(context, e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final c = context.kn;
    final isPhone = context.isPhoneWidth;
    final s = widget.coldSend.summary();
    final paid = s.payments.fold(BigInt.zero, (sum, p) => sum + p.amount);
    final contacts = {
      for (final contact in widget.wallet.contacts())
        contact.address: contact.name,
    };
    final pad = isPhone ? KnSpace.md : KnSpace.xl;

    return ListView(
      padding: EdgeInsets.fromLTRB(pad, pad, pad, pad),
      children: [
        Text(
          l.sendConfirmTitle,
          style: isPhone ? text.titleLarge : text.headlineSmall,
        ),
        const SizedBox(height: KnSpace.lg),
        KnCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Eyebrow(l.sendSendingLabel),
              const SizedBox(height: KnSpace.md),
              for (final p in s.payments) ...[
                if (contacts[p.address] != null) ...[
                  Text(contacts[p.address]!, style: text.bodyMedium),
                  const SizedBox(height: 2),
                ],
                AmountText(p.amount, size: text.titleLarge!.fontSize),
                const SizedBox(height: 2),
                Text(
                  p.address,
                  style: monoStyle(context, size: 13, color: c.textSecondary),
                ),
                const SizedBox(height: KnSpace.md),
              ],
              ...withDividers([
                KeyValue(label: l.sendFeeLine, value: AmountText(s.fee)),
                KeyValue(
                  label: l.sendTotalLine,
                  value: AmountText(paid + s.fee),
                  strong: true,
                ),
                if (s.change > BigInt.zero)
                  KeyValue(
                    label: l.sendChangeLine,
                    value: AmountText(s.change),
                  ),
              ]),
            ],
          ),
        ),
        const SizedBox(height: KnSpace.lg),
        Text(l.coldSignOnOfflineTitle, style: text.titleMedium),
        const SizedBox(height: KnSpace.md),
        Center(
          child: AnimatedQr(message: _message, registry: widget.registry),
        ),
        const SizedBox(height: KnSpace.lg),
        KnButton.primary(
          l.coldScanSignedAction,
          onPressed: _busy ? null : _scanSigned,
          expand: true,
        ),
        const SizedBox(height: KnSpace.sm),
        KnButton.text(
          l.sendEditAction,
          onPressed: _busy ? null : widget.onEdit,
        ),
      ],
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
    SendError.feeTooHigh => l.sendFeeTooHigh,
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
