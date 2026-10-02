import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../src/rust/api/wallets.dart';
import '../../theme/tokens.dart';
import '../../widgets/password_fields.dart';
import '../../widgets/wallet_error_text.dart';
import '../wallets/wallet_registry.dart';

class UnlockView extends StatefulWidget {
  const UnlockView({super.key, required this.wallet, required this.registry});

  final WalletSummary wallet;
  final WalletRegistry registry;

  @override
  State<UnlockView> createState() => _UnlockViewState();
}

class _UnlockViewState extends State<UnlockView> {
  final _password = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final wallet = await unlockWallet(
        id: widget.wallet.id,
        password: _password.text,
      );
      _password.clear();
      await widget.registry.opened(wallet);
    } on WalletError catch (e) {
      if (mounted) setState(() => _error = walletErrorMessage(context, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    return Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(KnSpace.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(widget.wallet.name, style: text.titleLarge),
              const SizedBox(height: KnSpace.lg),
              PasswordField(
                controller: _password,
                autofocus: true,
                errorText: _error,
                onSubmitted: (_) => _unlock(),
              ),
              const SizedBox(height: KnSpace.md),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton(
                  onPressed: _busy ? null : _unlock,
                  child: Text(l.unlockAction),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
