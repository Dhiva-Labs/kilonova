import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../platform/secure_window.dart';
import '../../src/rust/api/wallets.dart';
import '../../theme/tokens.dart';
import '../../widgets/password_fields.dart';
import '../../widgets/seed_grid.dart';
import '../../widgets/wallet_error_text.dart';
import '../wallets/wallet_registry.dart';

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
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(labelText: widget.hint),
        onSubmitted: (v) => Navigator.of(context).pop(v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l.cancelAction),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: Text(l.saveAction),
        ),
      ],
    );
  }
}

enum _WalletAction { showSeed, rename, changePassword, lock, delete }

class WalletMenu extends StatelessWidget {
  const WalletMenu({super.key, required this.wallet, required this.registry});

  final OpenWallet wallet;
  final WalletRegistry registry;

  Future<void> _run(BuildContext context, _WalletAction action) async {
    final l = AppLocalizations.of(context);
    final summary = wallet.summary();
    switch (action) {
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
        if ((changed ?? false) && context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(l.passwordChangedNotice)));
        }
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
          value: _WalletAction.showSeed,
          child: Text(l.showSeedAction),
        ),
        PopupMenuItem(value: _WalletAction.rename, child: Text(l.renameAction)),
        PopupMenuItem(
          value: _WalletAction.changePassword,
          child: Text(l.changePasswordAction),
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
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l.cancelAction),
          ),
        FilledButton(
          onPressed: revealed ? () => Navigator.of(context).pop() : _reveal,
          child: Text(revealed ? l.doneAction : l.showSeedAction),
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
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l.cancelAction),
        ),
        FilledButton(onPressed: _save, child: Text(l.saveAction)),
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
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l.cancelAction),
        ),
        FilledButton(onPressed: _delete, child: Text(l.deleteAction)),
      ],
    );
  }
}
