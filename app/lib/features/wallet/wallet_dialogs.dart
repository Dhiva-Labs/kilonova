import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../platform/secure_window.dart';
import '../../src/rust/api/wallets.dart';
import '../../theme/tokens.dart';
import '../../widgets/kn_button.dart';
import '../../widgets/kn_field.dart';
import '../../widgets/password_fields.dart';
import '../../widgets/seed_grid.dart';
import '../../widgets/wallet_error_text.dart';
import '../book/address_book_screen.dart';
import '../wallets/wallet_registry.dart';
import 'check_payment_screen.dart';
import 'coins_screen.dart';

/// Asks for one line of text. Returns `null` if cancelled.
Future<String?> askForText(
  BuildContext context, {
  required String title,
  required String hint,
  String initial = '',
}) => showDialog<String>(
  context: context,
  builder: (_) => _TextDialog(title: title, hint: hint, initial: initial),
);

/// Owns its controller, so the field outlives the closing animation.
class _TextDialog extends StatefulWidget {
  const _TextDialog({
    required this.title,
    required this.hint,
    required this.initial,
  });

  final String title;
  final String hint;
  final String initial;

  @override
  State<_TextDialog> createState() => _TextDialogState();
}

class _TextDialogState extends State<_TextDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(widget.title),
      content: KnField(
        controller: _controller,
        label: widget.hint,
        autofocus: true,
        onSubmitted: (v) => Navigator.of(context).pop(v),
      ),
      actions: [
        KnButton.text(
          l.cancelAction,
          onPressed: () => Navigator.of(context).pop(),
        ),
        KnButton.primary(
          l.saveAction,
          onPressed: () => Navigator.of(context).pop(_controller.text),
        ),
      ],
    );
  }
}

enum _WalletAction {
  addressBook,
  coins,
  checkPayment,
  showSeed,
  rename,
  changePassword,
  switchMode,
  biometricOn,
  biometricOff,
  makeCold,
  makeHot,
  lock,
  delete,
}

class WalletMenu extends StatefulWidget {
  const WalletMenu({super.key, required this.wallet, required this.registry});

  final OpenWallet wallet;
  final WalletRegistry registry;

  @override
  State<WalletMenu> createState() => _WalletMenuState();
}

class _WalletMenuState extends State<WalletMenu> {
  OpenWallet get wallet => widget.wallet;
  WalletRegistry get registry => widget.registry;

  bool _biometricAvailable = false;
  bool _biometricOn = false;

  @override
  void initState() {
    super.initState();
    _refreshBiometric();
  }

  Future<void> _refreshBiometric() async {
    final id = wallet.summary().id;
    final available = await registry.biometric.isAvailable();
    final on = await registry.biometric.isEnabled(id);
    if (mounted) {
      setState(() {
        _biometricAvailable = available;
        _biometricOn = on;
      });
    }
  }

  void _notice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _run(BuildContext context, _WalletAction action) async {
    final l = AppLocalizations.of(context);
    final summary = wallet.summary();
    switch (action) {
      case _WalletAction.addressBook:
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => AddressBookScreen(wallet: wallet),
          ),
        );
      case _WalletAction.coins:
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => CoinsScreen(wallet: wallet, registry: registry),
          ),
        );
      case _WalletAction.checkPayment:
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => CheckPaymentScreen(wallet: wallet),
          ),
        );
      case _WalletAction.showSeed:
        await showDialog<void>(
          context: context,
          builder: (_) => _RevealSeedDialog(wallet: wallet),
        );
      case _WalletAction.rename:
        final name = await askForText(
          context,
          title: l.renameAction,
          hint: l.walletNameLabel,
          initial: summary.name,
        );
        if (name == null || name.trim().isEmpty) return;
        await renameWallet(id: summary.id, name: name);
        await registry.reload();
      case _WalletAction.changePassword:
        final changed = await showDialog<bool>(
          context: context,
          builder: (_) => _ChangePasswordDialog(wallet: wallet),
        );
        if (!(changed ?? false)) return;
        if (_biometricOn) {
          // The stored password is now stale.
          await registry.biometric.disable(summary.id);
          await _refreshBiometric();
          _notice(l.biometricOffAfterPasswordChange);
        } else {
          _notice(l.passwordChangedNotice);
        }
      case _WalletAction.switchMode:
        final toLws = summary.mode == SyncMode.full;
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(l.switchModeTitle),
            content: SizedBox(
              width: 440,
              child: Text(toLws ? l.switchToLwsBody : l.switchToFullBody),
            ),
            actions: [
              KnButton.text(
                l.cancelAction,
                onPressed: () => Navigator.of(context).pop(false),
              ),
              KnButton.primary(
                l.switchAction,
                onPressed: () => Navigator.of(context).pop(true),
              ),
            ],
          ),
        );
        if (!(confirmed ?? false)) return;
        await wallet.setSyncMode(mode: toLws ? SyncMode.lws : SyncMode.full);
        await registry.reload();
        registry.startSync(summary.id);
      case _WalletAction.biometricOn:
        final password = await showDialog<String>(
          context: context,
          builder: (_) => _ConfirmPasswordDialog(walletId: summary.id),
        );
        if (password == null || !context.mounted) return;
        final enabled = await registry.biometric.enable(
          summary.id,
          password,
          title: l.biometricEnableTitle,
          cancel: l.cancelAction,
        );
        await _refreshBiometric();
        if (enabled) _notice(l.biometricEnabledNotice);
      case _WalletAction.biometricOff:
        await registry.biometric.disable(summary.id);
        await _refreshBiometric();
        _notice(l.biometricDisabledNotice);
      case _WalletAction.makeCold:
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(l.coldUseAsOfflineTitle),
            content: SizedBox(width: 420, child: Text(l.coldUseAsOfflineBody)),
            actions: [
              KnButton.text(
                l.cancelAction,
                onPressed: () => Navigator.of(context).pop(false),
              ),
              KnButton.primary(
                l.coldUseAsOfflineAction,
                onPressed: () => Navigator.of(context).pop(true),
              ),
            ],
          ),
        );
        if (!(confirmed ?? false)) return;
        await wallet.setCold(cold: true);
        await registry.reload();
      case _WalletAction.makeHot:
        await wallet.setCold(cold: false);
        await registry.reload();
        registry.startSync(summary.id);
      case _WalletAction.lock:
        registry.lock(summary.id);
      case _WalletAction.delete:
        final deleted = await showDialog<bool>(
          context: context,
          builder: (_) => _DeleteDialog(wallet: summary),
        );
        if (deleted ?? false) await registry.removed(summary.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return PopupMenuButton<_WalletAction>(
      tooltip: l.walletMenuTooltip,
      icon: const Icon(Icons.more_vert),
      onSelected: (a) => _run(context, a),
      itemBuilder: (_) => [
        PopupMenuItem(
          value: _WalletAction.addressBook,
          child: Text(l.bookTitle),
        ),
        PopupMenuItem(value: _WalletAction.coins, child: Text(l.coinsTitle)),
        PopupMenuItem(
          value: _WalletAction.checkPayment,
          child: Text(l.checkPaymentAction),
        ),
        PopupMenuItem(
          value: _WalletAction.showSeed,
          child: Text(l.showSeedAction),
        ),
        PopupMenuItem(value: _WalletAction.rename, child: Text(l.renameAction)),
        PopupMenuItem(
          value: _WalletAction.changePassword,
          child: Text(l.changePasswordAction),
        ),
        if (!wallet.summary().cold)
          PopupMenuItem(
            value: _WalletAction.switchMode,
            child: Text(
              wallet.summary().mode == SyncMode.full
                  ? l.switchToLwsAction
                  : l.switchToFullAction,
            ),
          ),
        if (_biometricAvailable)
          _biometricOn
              ? PopupMenuItem(
                  value: _WalletAction.biometricOff,
                  child: Text(l.biometricDisableAction),
                )
              : PopupMenuItem(
                  value: _WalletAction.biometricOn,
                  child: Text(l.biometricEnableAction),
                ),
        if (!wallet.summary().viewOnly)
          wallet.summary().cold
              ? PopupMenuItem(
                  value: _WalletAction.makeHot,
                  child: Text(l.coldStopOfflineAction),
                )
              : PopupMenuItem(
                  value: _WalletAction.makeCold,
                  child: Text(l.coldUseAsOfflineAction),
                ),
        PopupMenuItem(value: _WalletAction.lock, child: Text(l.lockAction)),
        PopupMenuItem(value: _WalletAction.delete, child: Text(l.deleteAction)),
      ],
    );
  }
}

class _RevealSeedDialog extends StatefulWidget {
  const _RevealSeedDialog({required this.wallet});

  final OpenWallet wallet;

  @override
  State<_RevealSeedDialog> createState() => _RevealSeedDialogState();
}

class _RevealSeedDialogState extends State<_RevealSeedDialog> {
  final _password = TextEditingController();
  String? _error;
  List<String>? _words;
  bool _noSeed = false;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _reveal() async {
    try {
      final words = await widget.wallet.revealSeed(password: _password.text);
      _password.clear();
      setState(() {
        _words = words;
        _noSeed = words == null;
        _error = null;
      });
    } on WalletError catch (e) {
      if (mounted) setState(() => _error = walletErrorMessage(context, e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final words = _words;
    final Widget content;
    if (words != null) {
      content = SecureWindow(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l.seedWarning),
            const SizedBox(height: KnSpace.md),
            SeedGrid(words: words),
          ],
        ),
      );
    } else if (_noSeed) {
      content = Text(l.noSeedNotice);
    } else {
      content = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l.showSeedPrompt),
          const SizedBox(height: KnSpace.md),
          PasswordField(
            controller: _password,
            autofocus: true,
            errorText: _error,
            onSubmitted: (_) => _reveal(),
          ),
        ],
      );
    }
    final revealed = words != null || _noSeed;
    return AlertDialog(
      title: Text(l.showSeedAction),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(child: content),
      ),
      actions: [
        if (!revealed)
          KnButton.text(
            l.cancelAction,
            onPressed: () => Navigator.of(context).pop(),
          ),
        KnButton.primary(
          revealed ? l.doneAction : l.showSeedAction,
          onPressed: revealed ? () => Navigator.of(context).pop() : _reveal,
        ),
      ],
    );
  }
}

class _ChangePasswordDialog extends StatefulWidget {
  const _ChangePasswordDialog({required this.wallet});

  final OpenWallet wallet;

  @override
  State<_ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<_ChangePasswordDialog> {
  final _form = GlobalKey<FormState>();
  final _current = TextEditingController();
  final _new = TextEditingController();
  final _confirm = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _current.dispose();
    _new.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    try {
      await widget.wallet.changePassword(
        current: _current.text,
        newPassword: _new.text,
      );
      if (mounted) Navigator.of(context).pop(true);
    } on WalletError catch (e) {
      if (mounted) setState(() => _error = walletErrorMessage(context, e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l.changePasswordAction),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PasswordField(
                controller: _current,
                autofocus: true,
                label: l.currentPasswordLabel,
                errorText: _error,
              ),
              const SizedBox(height: KnSpace.md),
              NewPasswordFields(
                password: _new,
                confirm: _confirm,
                label: l.newPasswordLabel,
              ),
            ],
          ),
        ),
      ),
      actions: [
        KnButton.text(
          l.cancelAction,
          onPressed: () => Navigator.of(context).pop(false),
        ),
        KnButton.primary(l.saveAction, onPressed: _save),
      ],
    );
  }
}

class _DeleteDialog extends StatefulWidget {
  const _DeleteDialog({required this.wallet});

  final WalletSummary wallet;

  @override
  State<_DeleteDialog> createState() => _DeleteDialogState();
}

class _DeleteDialogState extends State<_DeleteDialog> {
  final _password = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _delete() async {
    try {
      await deleteWallet(id: widget.wallet.id, password: _password.text);
      if (mounted) Navigator.of(context).pop(true);
    } on WalletError catch (e) {
      if (mounted) setState(() => _error = walletErrorMessage(context, e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l.deleteAction),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l.deleteWarning),
            const SizedBox(height: KnSpace.md),
            PasswordField(
              controller: _password,
              autofocus: true,
              errorText: _error,
              onSubmitted: (_) => _delete(),
            ),
          ],
        ),
      ),
      actions: [
        KnButton.text(
          l.cancelAction,
          onPressed: () => Navigator.of(context).pop(false),
        ),
        KnButton.primary(l.deleteAction, onPressed: _delete),
      ],
    );
  }
}

/// Asks for the wallet password and checks it, returning it if correct.
class _ConfirmPasswordDialog extends StatefulWidget {
  const _ConfirmPasswordDialog({required this.walletId});

  final String walletId;

  @override
  State<_ConfirmPasswordDialog> createState() => _ConfirmPasswordDialogState();
}

class _ConfirmPasswordDialogState extends State<_ConfirmPasswordDialog> {
  final _password = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    final password = _password.text;
    try {
      // Opening a second handle is the check; it is wiped right away.
      (await unlockWallet(id: widget.walletId, password: password)).lock();
      if (mounted) Navigator.of(context).pop(password);
    } on WalletError catch (e) {
      if (mounted) setState(() => _error = walletErrorMessage(context, e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l.biometricEnableAction),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l.biometricEnablePrompt),
            const SizedBox(height: KnSpace.md),
            PasswordField(
              controller: _password,
              autofocus: true,
              errorText: _error,
              onSubmitted: (_) => _confirm(),
            ),
          ],
        ),
      ),
      actions: [
        KnButton.text(
          l.cancelAction,
          onPressed: () => Navigator.of(context).pop(),
        ),
        KnButton.primary(l.continueAction, onPressed: _confirm),
      ],
    );
  }
}
