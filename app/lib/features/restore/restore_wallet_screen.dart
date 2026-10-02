import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../platform/secure_window.dart';
import '../../src/rust/api/network.dart';
import '../../src/rust/api/wallets.dart';
import '../../theme/tokens.dart';
import '../../widgets/error_line.dart';
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
                padding: const EdgeInsets.all(KnSpace.lg),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: Form(
                      key: _form,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(l.restoreMethodLabel, style: text.titleSmall),
                          const SizedBox(height: KnSpace.sm),
                          SegmentedButton<RestoreMethod>(
                            showSelectedIcon: false,
                            segments: [
                              ButtonSegment(
                                value: RestoreMethod.seed,
                                label: Text(l.restoreFromSeed),
                              ),
                              ButtonSegment(
                                value: RestoreMethod.spendKey,
                                label: Text(l.restoreFromSpendKey),
                              ),
                              ButtonSegment(
                                value: RestoreMethod.viewOnly,
                                label: Text(l.restoreViewOnly),
                              ),
                            ],
                            selected: {_method},
                            onSelectionChanged: (s) => setState(() {
                              _method = s.single;
                              _secret.clear();
                              _error = null;
                            }),
                          ),
                          if (_method == RestoreMethod.viewOnly) ...[
                            const SizedBox(height: KnSpace.sm),
                            Text(l.viewOnlyHelp, style: text.bodyMedium),
                          ],
                          const SizedBox(height: KnSpace.lg),
                          TextFormField(
                            controller: _name,
                            decoration: InputDecoration(
                              labelText: l.walletNameLabel,
                            ),
                            validator: (v) => (v ?? '').trim().isEmpty
                                ? l.errorEmptyName
                                : null,
                          ),
                          const SizedBox(height: KnSpace.md),
                          if (_method == RestoreMethod.viewOnly) ...[
                            TextFormField(
                              controller: _address,
                              autocorrect: false,
                              decoration: InputDecoration(
                                labelText: l.addressLabel,
                              ),
                            ),
                            const SizedBox(height: KnSpace.md),
                          ],
                          TextFormField(
                            controller: _secret,
                            autocorrect: false,
                            enableSuggestions: false,
                            minLines: _method == RestoreMethod.seed ? 3 : 1,
                            maxLines: _method == RestoreMethod.seed ? 5 : 1,
                            decoration: InputDecoration(
                              labelText: secretLabel,
                              helperText: _method == RestoreMethod.seed
                                  ? l.seedWordsHelp
                                  : null,
                              helperMaxLines: 2,
                            ),
                          ),
                          const SizedBox(height: KnSpace.md),
                          TextFormField(
                            controller: _height,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              labelText: l.restoreHeightLabel,
                              helperText: l.restoreHeightHelp,
                              helperMaxLines: 3,
                            ),
                            validator: (v) {
                              final s = (v ?? '').trim();
                              return s.isEmpty ||
                                      RegExp(r'^\d{1,12}$').hasMatch(s)
                                  ? null
                                  : l.restoreHeightInvalid;
                            },
                          ),
                          const SizedBox(height: KnSpace.lg),
                          Text(l.syncModeLabel, style: text.titleSmall),
                          RadioGroup<SyncMode>(
                            groupValue: _mode,
                            onChanged: (v) => setState(() => _mode = v!),
                            child: Column(
                              children: [
                                for (final mode in SyncMode.values)
                                  RadioListTile<SyncMode>(
                                    value: mode,
                                    contentPadding: EdgeInsets.zero,
                                    title: Text(mode.label(context)),
                                    subtitle: Text(mode.help(context)),
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(height: KnSpace.lg),
                          Text(l.passwordTitle, style: text.titleSmall),
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
                          Align(
                            alignment: Alignment.centerLeft,
                            child: FilledButton(
                              onPressed: _busy ? null : _restore,
                              child: Text(l.restoreAction),
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
