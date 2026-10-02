import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../platform/biometric_unlock.dart';
import '../../src/rust/api/wallets.dart';
import '../../theme/tokens.dart';
import '../../widgets/kn_button.dart';
import '../../widgets/password_fields.dart';
import '../../widgets/wallet_error_text.dart';
import '../wallets/wallet_registry.dart';

/// The unlock form for a locked wallet: name, password, unlock and the
/// biometric option.
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
  bool _biometric = false;

  @override
  void initState() {
    super.initState();
    widget.registry.biometric.isEnabled(widget.wallet.id).then((on) {
      if (mounted) setState(() => _biometric = on);
    });
  }

  Future<void> _unlockWithBiometric() async {
    final l = AppLocalizations.of(context);
    final biometric = widget.registry.biometric;
    try {
      final password = await biometric.unlock(
        widget.wallet.id,
        title: l.biometricPromptTitle(widget.wallet.name),
        cancel: l.cancelAction,
      );
      _password.text = password;
      await _unlock();
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
      _password.clear();
      if (mounted) setState(() => _error = walletErrorMessage(context, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(widget.wallet.name, style: text.headlineSmall),
        const SizedBox(height: KnSpace.lg),
        PasswordField(
          controller: _password,
          autofocus: true,
          errorText: _error,
          onSubmitted: (_) => _unlock(),
        ),
        const SizedBox(height: KnSpace.md),
        KnButton.primary(
          l.unlockAction,
          onPressed: _busy ? null : _unlock,
          expand: true,
        ),
        if (_biometric) ...[
          const SizedBox(height: KnSpace.sm),
          KnButton.text(
            l.biometricUnlockAction,
            onPressed: _busy ? null : _unlockWithBiometric,
          ),
        ],
      ],
    );
  }
}
