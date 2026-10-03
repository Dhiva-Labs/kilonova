import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../platform/biometric_unlock.dart';
import '../../platform/secure_window.dart';
import '../../src/rust/api/book.dart';
import '../../src/rust/api/sync.dart';
import '../../src/rust/api/wallets.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/amount.dart';
import '../../widgets/copy_value.dart';
import '../../widgets/kn_button.dart';
import '../../widgets/kn_card.dart';
import '../../widgets/kn_field.dart';
import '../../widgets/password_fields.dart';
import '../../widgets/wallet_error_text.dart';
import '../book/address_book_screen.dart';

/// One transaction: amount, status, the owner's note, who was paid, and the
/// transaction key for proving a payment.
class TxDetailsScreen extends StatefulWidget {
  const TxDetailsScreen({
    super.key,
    required this.wallet,
    required this.item,
    this.biometric = const BiometricUnlock(),
  });

  final OpenWallet wallet;
  final HistoryItem item;
  final BiometricUnlock biometric;

  @override
  State<TxDetailsScreen> createState() => _TxDetailsScreenState();
}

class _TxDetailsScreenState extends State<TxDetailsScreen> {
  late TxDetails _details = widget.wallet.txDetails(txHash: widget.item.txHash);
  late final _note = TextEditingController(text: _details.note);
  bool _noteSaved = true;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _saveNote() async {
    await widget.wallet.setTxNote(txHash: widget.item.txHash, note: _note.text);
    if (!mounted) return;
    setState(() {
      _details = widget.wallet.txDetails(txHash: widget.item.txHash);
      _noteSaved = true;
    });
  }

  void _copy(String text, String notice) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(notice)));
  }

  Future<void> _showKey() => showDialog<void>(
    context: context,
    builder: (_) => _TxKeyDialog(
      wallet: widget.wallet,
      txHash: widget.item.txHash,
      biometric: widget.biometric,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final c = context.kn;
    final item = widget.item;
    final status = item.pending
        ? l.historyPending
        : l.historyBlock(item.height.toString());
    final contacts = {
      for (final contact in widget.wallet.contacts())
        contact.address: contact.name,
    };

    return Scaffold(
      appBar: AppBar(title: Text(l.txDetailsTitle)),
      body: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.all(KnSpace.lg),
            children: [
              AmountText(
                item.amount,
                size: text.headlineSmall!.fontSize,
                prefix: item.incoming ? '+' : '-',
                color: item.incoming ? c.received : c.text,
              ),
              const SizedBox(height: KnSpace.xs),
              Text(
                [
                  item.incoming ? l.historyReceived : l.historySent,
                  status,
                ].join(' · '),
                style: text.bodySmall,
              ),
              const SizedBox(height: KnSpace.lg),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(child: Eyebrow(l.txIdLabel)),
                  KnIconButton(
                    icon: const Icon(Icons.copy_outlined),
                    tooltip: l.historyCopyTx,
                    onPressed: () => _copy(item.txHash, l.txCopiedNotice),
                  ),
                ],
              ),
              const SizedBox(height: KnSpace.xs),
              SelectableText(item.txHash, style: monoStyle(context, size: 13)),
              const SizedBox(height: KnSpace.lg),
              KnField(
                controller: _note,
                label: l.txNoteField,
                multiline: true,
                onChanged: (_) => setState(() => _noteSaved = false),
                onSubmitted: (_) => _saveNote(),
              ),
              if (!_noteSaved) ...[
                const SizedBox(height: KnSpace.sm),
                Align(
                  alignment: Alignment.centerLeft,
                  child: KnButton.text(
                    l.txNoteSaveAction,
                    onPressed: _saveNote,
                  ),
                ),
              ],
              if (_details.destinations.isNotEmpty) ...[
                const SizedBox(height: KnSpace.lg),
                Eyebrow(l.txRecipientsLabel),
                const SizedBox(height: KnSpace.sm),
                KnCard(
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: withDividers([
                      for (final p in _details.destinations)
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: KnSpace.md,
                            vertical: KnSpace.md,
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    AmountText(p.amount),
                                    const SizedBox(height: 2),
                                    if (contacts[p.address] != null)
                                      Text(
                                        contacts[p.address]!,
                                        style: text.bodyMedium,
                                      ),
                                    SelectableText(
                                      p.address,
                                      style: monoStyle(
                                        context,
                                        size: 13,
                                        color: c.textSecondary,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              KnIconButton(
                                icon: const Icon(Icons.copy_outlined),
                                tooltip: l.copyAction,
                                onPressed: () => _copy(
                                  p.address,
                                  l.copiedGeneric(l.addressCopyLabel),
                                ),
                              ),
                              if (contacts[p.address] == null)
                                KnButton.text(
                                  l.bookSaveRecipientAction,
                                  onPressed: () async {
                                    await showContactDialog(
                                      context,
                                      wallet: widget.wallet,
                                      address: p.address,
                                    );
                                    if (mounted) setState(() {});
                                  },
                                ),
                            ],
                          ),
                        ),
                    ]),
                  ),
                ),
              ],
              if (_details.hasTxKey) ...[
                const SizedBox(height: KnSpace.lg),
                KnCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l.txKeyHelp, style: text.bodySmall),
                      const SizedBox(height: KnSpace.sm),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: KnButton.text(
                          l.txKeyShowAction,
                          onPressed: _showKey,
                        ),
                      ),
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

class _TxKeyDialog extends StatefulWidget {
  const _TxKeyDialog({
    required this.wallet,
    required this.txHash,
    required this.biometric,
  });

  final OpenWallet wallet;
  final String txHash;
  final BiometricUnlock biometric;

  @override
  State<_TxKeyDialog> createState() => _TxKeyDialogState();
}

class _TxKeyDialogState extends State<_TxKeyDialog> {
  final _password = TextEditingController();
  String? _error;
  String? _key;
  bool _biometric = false;

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

  Future<void> _reveal() async {
    try {
      final key = await widget.wallet.revealTxKey(
        txHash: widget.txHash,
        password: _password.text,
      );
      _password.clear();
      if (mounted) setState(() => _key = key);
    } on WalletError catch (e) {
      _password.clear();
      if (mounted) setState(() => _error = walletErrorMessage(context, e));
    }
  }

  Future<void> _revealWithBiometric() async {
    final l = AppLocalizations.of(context);
    final summary = widget.wallet.summary();
    try {
      _password.text = await widget.biometric.unlock(
        summary.id,
        title: l.biometricPromptTitle(summary.name),
        cancel: l.cancelAction,
      );
      await _reveal();
    } on BiometricException catch (e) {
      if (!mounted || e.failure == BiometricFailure.cancelled) return;
      setState(() => _error = l.biometricFailed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final key = _key;
    return AlertDialog(
      title: Text(l.txKeyTitle),
      content: SizedBox(
        width: 560,
        child: key == null
            ? Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(l.txKeyPrompt),
                  const SizedBox(height: KnSpace.md),
                  PasswordField(
                    controller: _password,
                    autofocus: true,
                    errorText: _error,
                    onSubmitted: (_) => _reveal(),
                  ),
                ],
              )
            : SecureWindow(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(l.txKeyWarning),
                    const SizedBox(height: KnSpace.md),
                    CopyValue(label: l.transactionKeyLabel, value: key),
                  ],
                ),
              ),
      ),
      actions: [
        if (key == null && _biometric)
          KnButton.text(
            l.biometricUnlockAction,
            onPressed: _revealWithBiometric,
          ),
        if (key == null) KnButton.text(l.txKeyShowAction, onPressed: _reveal),
        KnButton.text(
          l.closeAction,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}
