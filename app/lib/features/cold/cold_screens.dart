import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../platform/biometric_unlock.dart';
import '../../src/rust/api/cold.dart';
import '../../src/rust/api/wallets.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/amount.dart';
import '../../widgets/kn_button.dart';
import '../../widgets/kn_card.dart';
import '../../widgets/kn_field.dart';
import '../../widgets/password_fields.dart';
import '../wallets/wallet_registry.dart';
import 'animated_qr.dart';
import 'cold_failure_text.dart';

void _notice(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

/// A full screen holding an [AnimatedQr] with a title, an optional note,
/// and a done button. Used for every "show this to the other device" step.
class ColdShowScreen extends StatelessWidget {
  const ColdShowScreen({
    super.key,
    required this.title,
    required this.message,
    required this.registry,
    this.note,
  });

  final String title;
  final ColdMessage message;
  final WalletRegistry registry;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(KnSpace.lg),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedQr(message: message, registry: registry),
                  if (note != null) ...[
                    const SizedBox(height: KnSpace.md),
                    Text(
                      note!,
                      style: text.bodySmall,
                      textAlign: TextAlign.center,
                    ),
                  ],
                  const SizedBox(height: KnSpace.lg),
                  KnButton.primary(
                    l.doneAction,
                    onPressed: () => Navigator.of(context).pop(),
                    expand: true,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Asks for the wallet password, for a step that signs or decrypts.
Future<String?> _askPassword(
  BuildContext context, {
  required String title,
  String? error,
}) => showDialog<String>(
  context: context,
  builder: (_) => _PasswordDialog(title: title, error: error),
);

class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog({required this.title, this.error});

  final String title;
  final String? error;

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final _password = TextEditingController();

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 360,
        child: PasswordField(
          controller: _password,
          autofocus: true,
          errorText: widget.error,
          onSubmitted: (_) => Navigator.of(context).pop(_password.text),
        ),
      ),
      actions: [
        KnButton.text(
          l.cancelAction,
          onPressed: () => Navigator.of(context).pop(),
        ),
        KnButton.primary(
          l.continueAction,
          onPressed: () => Navigator.of(context).pop(_password.text),
        ),
      ],
    );
  }
}

/// Cold wallet: pairs with a new watching wallet. Asks for the password,
/// then shows the pairing code.
Future<void> coldPair(
  BuildContext context,
  OpenWallet wallet,
  WalletRegistry registry,
) async {
  final l = AppLocalizations.of(context);
  final password = await _askPassword(context, title: l.coldPairAction);
  if (password == null || !context.mounted) return;
  try {
    final message = await wallet.coldPairing(password: password);
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ColdShowScreen(
          title: l.coldShowToWatchingTitle,
          message: message,
          registry: registry,
          note: l.coldPairingWarning,
        ),
      ),
    );
  } on ColdFailure catch (e) {
    if (context.mounted) _notice(context, coldFailureMessage(context, e));
  }
}

/// Cold wallet: scans a request (sync or sign) and answers it.
Future<void> coldScanRequest(
  BuildContext context,
  OpenWallet wallet,
  WalletRegistry registry,
) async {
  final l = AppLocalizations.of(context);
  final bytes = await registry.cold.receive(
    context,
    title: l.coldScanRequestAction,
  );
  if (bytes == null || !context.mounted) return;
  ColdKind kind;
  try {
    kind = coldMessageKind(message: bytes);
  } on ColdFailure catch (e) {
    _notice(context, coldFailureMessage(context, e));
    return;
  }
  switch (kind) {
    case ColdKind.syncRequest:
      await _answerSyncRequest(context, wallet, bytes, registry);
    case ColdKind.signRequest:
      await _reviewSignRequest(context, wallet, bytes, registry);
    case ColdKind.pairing:
    case ColdKind.syncAnswer:
    case ColdKind.signed:
      _notice(context, coldFailureMessage(context, ColdFailure.wrongKind));
  }
}

Future<void> _answerSyncRequest(
  BuildContext context,
  OpenWallet wallet,
  List<int> bytes,
  WalletRegistry registry,
) async {
  final l = AppLocalizations.of(context);
  try {
    final request = await wallet.readColdRequest(message: bytes);
    final answer = await wallet.answerColdRequest(
      request: request,
      password: '',
    );
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ColdShowScreen(
          title: l.coldShowToWatchingTitle,
          message: answer,
          registry: registry,
        ),
      ),
    );
  } on ColdFailure catch (e) {
    if (context.mounted) _notice(context, coldFailureMessage(context, e));
  }
}

Future<void> _reviewSignRequest(
  BuildContext context,
  OpenWallet wallet,
  List<int> bytes,
  WalletRegistry registry,
) async {
  try {
    final request = await wallet.readColdRequest(message: bytes);
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _SignReviewScreen(
          wallet: wallet,
          request: request,
          registry: registry,
        ),
      ),
    );
  } on ColdFailure catch (e) {
    if (context.mounted) _notice(context, coldFailureMessage(context, e));
  }
}

/// What a sign request will do, read from the transaction itself, with a
/// password step that signs it.
class _SignReviewScreen extends StatefulWidget {
  const _SignReviewScreen({
    required this.wallet,
    required this.request,
    required this.registry,
  });

  final OpenWallet wallet;
  final ColdRequest request;
  final WalletRegistry registry;

  @override
  State<_SignReviewScreen> createState() => _SignReviewScreenState();
}

class _SignReviewScreenState extends State<_SignReviewScreen> {
  final _password = TextEditingController();
  bool _busy = false;
  bool _biometric = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.registry.biometric.isEnabled(widget.wallet.summary().id).then((on) {
      if (mounted) setState(() => _biometric = on);
    });
  }

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _sign(String password) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final answer = await widget.wallet.answerColdRequest(
        request: widget.request,
        password: password,
      );
      _password.clear();
      if (!mounted) return;
      final l = AppLocalizations.of(context);
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => ColdShowScreen(
            title: l.coldShowToWatchingTitle,
            message: answer,
            registry: widget.registry,
          ),
        ),
      );
    } on ColdFailure catch (e) {
      if (!mounted) return;
      setState(
        () => _error = e == ColdFailure.wrongPassword
            ? AppLocalizations.of(context).errorWrongPassword
            : coldFailureMessage(context, e),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signWithBiometric() async {
    final l = AppLocalizations.of(context);
    final summary = widget.wallet.summary();
    try {
      final password = await widget.registry.biometric.unlock(
        summary.id,
        title: l.biometricSendTitle(summary.name),
        cancel: l.cancelAction,
      );
      await _sign(password);
    } on BiometricException catch (e) {
      if (!mounted || e.failure == BiometricFailure.cancelled) return;
      setState(() {
        _error = e.failure == BiometricFailure.invalidated
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
    final s = widget.request.summary();
    final contacts = {
      for (final contact in widget.wallet.contacts())
        contact.address: contact.name,
    };
    final paid = s.payments.fold(BigInt.zero, (sum, p) => sum + p.amount);

    return Scaffold(
      appBar: AppBar(title: Text(l.coldCheckBeforeSigningTitle)),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              padding: const EdgeInsets.all(KnSpace.lg),
              children: [
                KnCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Eyebrow(l.coldSigningEyebrow),
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
                          style: monoStyle(
                            context,
                            size: 13,
                            color: c.textSecondary,
                          ),
                        ),
                        const SizedBox(height: KnSpace.md),
                      ],
                      ...withDividers([
                        KeyValue(
                          label: l.sendFeeLine,
                          value: AmountText(s.fee),
                        ),
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
                      Text(
                        l.coldCoinsSpentLabel(s.inputs),
                        style: text.bodySmall,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: KnSpace.sm),
                Text(l.coldReadFromTxNote, style: text.bodySmall),
                const SizedBox(height: KnSpace.lg),
                PasswordField(
                  controller: _password,
                  autofocus: true,
                  errorText: _error,
                  onSubmitted: (_) => _sign(_password.text),
                ),
                const SizedBox(height: KnSpace.md),
                Wrap(
                  spacing: KnSpace.sm,
                  runSpacing: KnSpace.sm,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    KnButton.primary(
                      l.coldSignAction,
                      onPressed: _busy ? null : () => _sign(_password.text),
                    ),
                    if (_biometric)
                      KnButton.text(
                        l.biometricSendAction,
                        onPressed: _busy ? null : _signWithBiometric,
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Watching wallet: syncs with its offline wallet to learn key images for
/// coins it has seen but cannot yet spend.
Future<void> coldSyncWithOffline(
  BuildContext context,
  OpenWallet wallet,
  WalletRegistry registry,
) async {
  final request = await wallet.coldSyncRequest();
  if (!context.mounted) return;
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => _SyncWithOfflineScreen(
        wallet: wallet,
        request: request,
        registry: registry,
      ),
    ),
  );
}

class _SyncWithOfflineScreen extends StatelessWidget {
  const _SyncWithOfflineScreen({
    required this.wallet,
    required this.request,
    required this.registry,
  });

  final OpenWallet wallet;
  final ColdMessage request;
  final WalletRegistry registry;

  Future<void> _scanAnswer(BuildContext context) async {
    final l = AppLocalizations.of(context);
    final bytes = await registry.cold.receive(
      context,
      title: l.coldScanAnswerAction,
    );
    if (bytes == null || !context.mounted) return;
    try {
      final imported = await wallet.importColdAnswer(
        message: bytes,
        destinations: const [],
      );
      registry.startSync(wallet.summary().id);
      if (!context.mounted) return;
      Navigator.of(context).pop();
      _notice(context, l.coldLearnedKeyImagesNotice(imported.keyImages));
    } on ColdFailure catch (e) {
      if (context.mounted) _notice(context, coldFailureMessage(context, e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l.coldShowToOfflineTitle)),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(KnSpace.lg),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedQr(message: request, registry: registry),
                  const SizedBox(height: KnSpace.lg),
                  KnButton.primary(
                    l.coldScanAnswerAction,
                    onPressed: () => _scanAnswer(context),
                    expand: true,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Watching side: scans a pairing code and creates the watching wallet.
/// Returns the new wallet's id, or null if cancelled or not a pairing
/// code.
Future<String?> openPairWithOfflineWallet(
  BuildContext context,
  WalletRegistry registry,
) async {
  final l = AppLocalizations.of(context);
  final bytes = await registry.cold.receive(
    context,
    title: l.coldScanPairingTitle,
  );
  if (bytes == null || !context.mounted) return null;
  try {
    if (coldMessageKind(message: bytes) != ColdKind.pairing) {
      _notice(context, coldFailureMessage(context, ColdFailure.wrongKind));
      return null;
    }
  } on ColdFailure catch (e) {
    _notice(context, coldFailureMessage(context, e));
    return null;
  }
  if (!context.mounted) return null;
  return Navigator.of(context).push<String>(
    MaterialPageRoute(
      builder: (_) => _CreateWatchingScreen(message: bytes, registry: registry),
    ),
  );
}

class _CreateWatchingScreen extends StatefulWidget {
  const _CreateWatchingScreen({required this.message, required this.registry});

  final List<int> message;
  final WalletRegistry registry;

  @override
  State<_CreateWatchingScreen> createState() => _CreateWatchingScreenState();
}

class _CreateWatchingScreenState extends State<_CreateWatchingScreen> {
  final _name = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final l = AppLocalizations.of(context);
    if (_name.text.trim().isEmpty) {
      setState(() => _error = l.errorEmptyName);
      return;
    }
    if (_password.text.length < minPasswordLength) {
      setState(() => _error = l.passwordTooShort);
      return;
    }
    if (_password.text != _confirm.text) {
      setState(() => _error = l.passwordMismatch);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final wallet = await createWatchingWallet(
        name: _name.text.trim(),
        message: widget.message,
        password: _password.text,
        mode: SyncMode.full,
      );
      await widget.registry.opened(wallet);
      if (!mounted) return;
      Navigator.of(context).pop(wallet.summary().id);
    } on ColdFailure catch (e) {
      if (mounted) setState(() => _error = coldFailureMessage(context, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l.coldPairWatchingMenuAction)),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(KnSpace.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  KnField(
                    controller: _name,
                    label: l.walletNameLabel,
                    autofocus: true,
                    enabled: !_busy,
                  ),
                  const SizedBox(height: KnSpace.md),
                  NewPasswordFields(password: _password, confirm: _confirm),
                  if (_error != null) ...[
                    const SizedBox(height: KnSpace.md),
                    Text(
                      _error!,
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall!.copyWith(color: context.kn.error),
                    ),
                  ],
                  const SizedBox(height: KnSpace.lg),
                  KnButton.primary(
                    l.coldCreateWatchingAction,
                    onPressed: _busy ? null : _create,
                    expand: true,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
