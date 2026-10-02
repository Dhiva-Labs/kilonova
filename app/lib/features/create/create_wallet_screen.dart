import 'dart:math';

import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../platform/secure_window.dart';
import '../../src/rust/api/network.dart';
import '../../src/rust/api/sync.dart';
import '../../src/rust/api/wallets.dart';
import '../../theme/tokens.dart';
import '../../widgets/mode_label.dart';
import '../../widgets/error_line.dart';
import '../../widgets/password_fields.dart';
import '../../widgets/seed_grid.dart';
import '../../widgets/test_network_strip.dart';
import '../../widgets/wallet_error_text.dart';
import '../wallets/wallet_registry.dart';

enum _Step { options, seed, verify, password }

/// Creates a wallet: options, write down the seed, check three words, set a
/// password. Pops with the new wallet's id.
class CreateWalletScreen extends StatefulWidget {
  const CreateWalletScreen({
    super.key,
    required this.network,
    required this.registry,
    this.random,
  });

  final Network network;
  final WalletRegistry registry;

  /// Picks which words to check. Injectable so tests are deterministic.
  final Random? random;

  @override
  State<CreateWalletScreen> createState() => _CreateWalletScreenState();
}

class _CreateWalletScreenState extends State<CreateWalletScreen> {
  var _step = _Step.options;
  final _name = TextEditingController();
  var _format = SeedFormat.polyseed;
  var _mode = SyncMode.full;
  List<String> _words = const [];
  List<int> _checkPositions = const [];
  final _checks = [for (var i = 0; i < 3; i++) TextEditingController()];
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _passwordForm = GlobalKey<FormState>();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [_name, _password, _confirm, ..._checks]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _generate() async {
    final l = AppLocalizations.of(context);
    if (_name.text.trim().isEmpty) {
      setState(() => _error = l.errorEmptyName);
      return;
    }
    final seed = await generateSeed(format: _format);
    final random = widget.random ?? Random.secure();
    final positions = <int>{};
    while (positions.length < 3) {
      positions.add(random.nextInt(seed.words.length));
    }
    setState(() {
      _words = seed.words;
      _checkPositions = positions.toList()..sort();
      _error = null;
      _step = _Step.seed;
    });
  }

  void _verify() {
    for (var i = 0; i < 3; i++) {
      if (_checks[i].text.trim().toLowerCase() != _words[_checkPositions[i]]) {
        setState(() => _error = AppLocalizations.of(context).verifyWrong);
        return;
      }
    }
    setState(() {
      _error = null;
      _step = _Step.password;
    });
  }

  Future<void> _create() async {
    if (_busy || !_passwordForm.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      final wallet = await createWalletFromSeed(
        name: _name.text,
        network: widget.network,
        mode: _mode,
        words: _words.join(' '),
        password: _password.text,
        // A new wallet has no history before today.
        restoreHeight: restoreHeightForNewWallet(network: widget.network),
        createdHere: true,
      );
      _words = const [];
      await widget.registry.opened(wallet);
      if (mounted) Navigator.of(context).pop(wallet.summary().id);
    } on WalletError catch (e) {
      if (mounted) setState(() => _error = walletErrorMessage(context, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _back() {
    setState(() {
      _error = null;
      _step = switch (_step) {
        _Step.options => _Step.options,
        _Step.seed => _Step.options,
        _Step.verify => _Step.seed,
        _Step.password => _Step.verify,
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final body = switch (_step) {
      _Step.options => _options(context),
      _Step.seed => SecureWindow(child: _seed(context)),
      _Step.verify => SecureWindow(child: _verifyStep(context)),
      _Step.password => _passwordStep(context),
    };
    return PopScope(
      canPop: _step == _Step.options,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        appBar: AppBar(title: Text(l.createTitle)),
        body: Column(
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
                    child: body,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _options(BuildContext context) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _name,
          autofocus: true,
          decoration: InputDecoration(
            labelText: l.walletNameLabel,
            errorText: _error,
          ),
        ),
        const SizedBox(height: KnSpace.lg),
        Text(l.seedFormatLabel, style: text.titleSmall),
        RadioGroup<SeedFormat>(
          groupValue: _format,
          onChanged: (v) => setState(() => _format = v!),
          child: Column(
            children: [
              _choice(SeedFormat.polyseed, l.seedPolyseed, l.seedPolyseedHelp),
              _choice(SeedFormat.classic, l.seedClassic, l.seedClassicHelp),
            ],
          ),
        ),
        const SizedBox(height: KnSpace.md),
        Text(l.syncModeLabel, style: text.titleSmall),
        RadioGroup<SyncMode>(
          groupValue: _mode,
          onChanged: (v) => setState(() => _mode = v!),
          child: Column(
            children: [
              for (final mode in SyncMode.values)
                _choice(mode, mode.label(context), mode.help(context)),
            ],
          ),
        ),
        const SizedBox(height: KnSpace.lg),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton(
            onPressed: _generate,
            child: Text(l.continueAction),
          ),
        ),
      ],
    );
  }

  Widget _choice<T>(T value, String title, String help) => RadioListTile<T>(
    value: value,
    contentPadding: EdgeInsets.zero,
    title: Text(title),
    subtitle: Text(help),
  );

  Widget _seed(BuildContext context) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l.seedTitle, style: text.titleLarge),
        const SizedBox(height: KnSpace.sm),
        Text(l.seedWarning, style: text.bodyLarge),
        const SizedBox(height: KnSpace.lg),
        SeedGrid(words: _words),
        const SizedBox(height: KnSpace.lg),
        Row(
          children: [
            FilledButton(
              onPressed: () => setState(() => _step = _Step.verify),
              child: Text(l.seedWrittenAction),
            ),
            const SizedBox(width: KnSpace.sm),
            TextButton(onPressed: _back, child: Text(l.backAction)),
          ],
        ),
      ],
    );
  }

  Widget _verifyStep(BuildContext context) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l.verifyTitle, style: text.titleLarge),
        const SizedBox(height: KnSpace.lg),
        for (var i = 0; i < 3; i++) ...[
          TextField(
            controller: _checks[i],
            autofocus: i == 0,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: l.verifyPrompt(_checkPositions[i] + 1),
            ),
          ),
          const SizedBox(height: KnSpace.md),
        ],
        if (_error != null) ...[
          ErrorLine(_error!),
          const SizedBox(height: KnSpace.md),
        ],
        Row(
          children: [
            FilledButton(onPressed: _verify, child: Text(l.continueAction)),
            const SizedBox(width: KnSpace.sm),
            TextButton(onPressed: _back, child: Text(l.backAction)),
          ],
        ),
      ],
    );
  }

  Widget _passwordStep(BuildContext context) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    return Form(
      key: _passwordForm,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l.passwordTitle, style: text.titleLarge),
          const SizedBox(height: KnSpace.sm),
          Text(l.passwordHelp, style: text.bodyLarge),
          const SizedBox(height: KnSpace.lg),
          NewPasswordFields(password: _password, confirm: _confirm),
          if (_error != null) ...[
            const SizedBox(height: KnSpace.md),
            ErrorLine(_error!),
          ],
          const SizedBox(height: KnSpace.lg),
          Row(
            children: [
              FilledButton(
                onPressed: _busy ? null : _create,
                child: Text(l.createAction),
              ),
              const SizedBox(width: KnSpace.sm),
              TextButton(onPressed: _back, child: Text(l.backAction)),
            ],
          ),
        ],
      ),
    );
  }
}
