import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../platform/secure_window.dart';
import '../../src/rust/api/network.dart';
import '../../src/rust/api/wallets.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/error_line.dart';
import '../../widgets/kn_button.dart';
import '../../widgets/kn_card.dart';
import '../../widgets/kn_field.dart';
import '../../widgets/kn_segments.dart';
import '../../widgets/mode_label.dart';
import '../../widgets/password_fields.dart';
import '../../widgets/test_network_strip.dart';
import '../../widgets/wallet_error_text.dart';
import '../wallets/wallet_registry.dart';

enum RestoreMethod { seed, spendKey, viewOnly }

/// Restores a wallet from seed words, a spend key, or as view-only from an
/// address and view key. Pops with the wallet's id.
class RestoreWalletScreen extends StatefulWidget {
  const RestoreWalletScreen({
    super.key,
    required this.network,
    required this.registry,
  });

  final Network network;
  final WalletRegistry registry;

  @override
  State<RestoreWalletScreen> createState() => _RestoreWalletScreenState();
}

class _RestoreWalletScreenState extends State<RestoreWalletScreen> {
  final _form = GlobalKey<FormState>();
  var _method = RestoreMethod.seed;
  var _mode = SyncMode.full;
  final _name = TextEditingController();
  final _secret = TextEditingController();
  final _address = TextEditingController();
  final _height = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [_name, _secret, _address, _height, _password, _confirm]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _restore() async {
    if (_busy || !_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final height = _height.text.trim().isEmpty
        ? null
        : BigInt.parse(_height.text.trim());
    try {
      final wallet = await switch (_method) {
        RestoreMethod.seed => createWalletFromSeed(
          name: _name.text,
          network: widget.network,
          mode: _mode,
          words: _secret.text,
          password: _password.text,
          restoreHeight: height,
          createdHere: false,
        ),
        RestoreMethod.spendKey => createWalletFromSpendKey(
          name: _name.text,
          network: widget.network,
          mode: _mode,
          spendKey: _secret.text,
          password: _password.text,
          restoreHeight: height,
        ),
        RestoreMethod.viewOnly => createViewOnlyWallet(
          name: _name.text,
          network: widget.network,
          mode: _mode,
          address: _address.text,
          viewKey: _secret.text,
          password: _password.text,
          restoreHeight: height,
        ),
      };
      _secret.clear();
      await widget.registry.opened(wallet);
      if (mounted) Navigator.of(context).pop(wallet.summary().id);
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
    final phone = context.isPhoneWidth;
    final secretLabel = switch (_method) {
      RestoreMethod.seed => l.seedWordsLabel,
      RestoreMethod.spendKey => l.spendKeyLabel,
      RestoreMethod.viewOnly => l.viewKeyLabel,
    };

    return Scaffold(
      appBar: AppBar(title: Text(l.restoreTitle)),
      body: SecureWindow(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TestNetworkStrip(network: widget.network),
            Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.all(phone ? KnSpace.md : KnSpace.xl),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: Form(
                      key: _form,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(l.restoreMethodLabel, style: text.titleMedium),
                          const SizedBox(height: KnSpace.sm),
                          KnSegments<RestoreMethod>(
                            segments: [
                              KnSegment(RestoreMethod.seed, l.restoreFromSeed),
                              KnSegment(
                                RestoreMethod.spendKey,
                                l.restoreFromSpendKey,
                              ),
                              KnSegment(
                                RestoreMethod.viewOnly,
                                l.restoreViewOnly,
                              ),
                            ],
                            selected: _method,
                            onChanged: (m) => setState(() {
                              _method = m;
                              _secret.clear();
                              _error = null;
                            }),
                          ),
                          if (_method == RestoreMethod.viewOnly) ...[
                            const SizedBox(height: KnSpace.sm),
                            Text(l.viewOnlyHelp, style: text.bodyMedium),
                          ],
                          const SizedBox(height: KnSpace.lg),
                          KnField(
                            controller: _name,
                            label: l.walletNameLabel,
                            validator: (v) => (v ?? '').trim().isEmpty
                                ? l.errorEmptyName
                                : null,
                          ),
                          const SizedBox(height: KnSpace.md),
                          if (_method == RestoreMethod.viewOnly) ...[
                            KnField(
                              controller: _address,
                              label: l.addressLabel,
                            ),
                            const SizedBox(height: KnSpace.md),
                          ],
                          KnField(
                            controller: _secret,
                            label: secretLabel,
                            multiline: _method == RestoreMethod.seed,
                            helper: _method == RestoreMethod.seed
                                ? l.seedWordsHelp
                                : null,
                          ),
                          const SizedBox(height: KnSpace.md),
                          KnField(
                            controller: _height,
                            keyboardType: TextInputType.number,
                            label: l.restoreHeightLabel,
                            helper: l.restoreHeightHelp,
                            validator: (v) {
                              final s = (v ?? '').trim();
                              return s.isEmpty ||
                                      RegExp(r'^\d{1,12}$').hasMatch(s)
                                  ? null
                                  : l.restoreHeightInvalid;
                            },
                          ),
                          const SizedBox(height: KnSpace.lg),
                          Text(l.syncModeLabel, style: text.titleMedium),
                          const SizedBox(height: KnSpace.sm),
                          RadioGroup<SyncMode>(
                            groupValue: _mode,
                            onChanged: (v) => setState(() => _mode = v!),
                            child: KnCard(
                              padding: EdgeInsets.zero,
                              child: Column(
                                children: withDividers([
                                  for (final mode in SyncMode.values)
                                    KnRow(
                                      onTap: () => setState(() => _mode = mode),
                                      leading: Radio<SyncMode>(value: mode),
                                      title: Text(mode.label(context)),
                                      subtitle: Text(mode.help(context)),
                                    ),
                                ]),
                              ),
                            ),
                          ),
                          const SizedBox(height: KnSpace.lg),
                          Text(l.passwordTitle, style: text.titleMedium),
                          const SizedBox(height: KnSpace.sm),
                          NewPasswordFields(
                            password: _password,
                            confirm: _confirm,
                          ),
                          if (_error != null) ...[
                            const SizedBox(height: KnSpace.md),
                            ErrorLine(_error!),
                          ],
                          const SizedBox(height: KnSpace.lg),
                          phone
                              ? KnButton.primary(
                                  l.restoreAction,
                                  onPressed: _busy ? null : _restore,
                                  expand: true,
                                )
                              : Align(
                                  alignment: Alignment.centerLeft,
                                  child: KnButton.primary(
                                    l.restoreAction,
                                    onPressed: _busy ? null : _restore,
                                  ),
                                ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
