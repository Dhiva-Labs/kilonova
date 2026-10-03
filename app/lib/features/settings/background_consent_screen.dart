import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../src/rust/api/background.dart';
import '../../src/rust/api/wallets.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/error_line.dart';
import '../../widgets/kn_button.dart';
import '../../widgets/kn_card.dart';
import '../../widgets/network_label.dart';
import '../../widgets/password_fields.dart';
import '../wallets/wallet_registry.dart';

/// What turning on background work means, said before it happens. On
/// Android: checks for payments with the app closed, which need the
/// notification permission and, per wallet, its password once. On
/// desktops: keeping wallets syncing with the window closed. Pops `true`
/// once the owner turned it on; the caller saves the setting on desktops.
class BackgroundConsentScreen extends StatefulWidget {
  const BackgroundConsentScreen({
    super.key,
    required this.registry,
    required this.desktop,
  });

  final WalletRegistry registry;

  /// Linux and Windows: the window-closed variant, with no checks.
  final bool desktop;

  @override
  State<BackgroundConsentScreen> createState() =>
      _BackgroundConsentScreenState();
}

class _BackgroundConsentScreenState extends State<BackgroundConsentScreen> {
  bool _choosing = false;
  bool _denied = false;
  bool _done = false;
  Set<String> _chosen = const {};

  @override
  void dispose() {
    // Left without turning it on: nothing chosen on the way is kept.
    if (!_done && _chosen.isNotEmpty) {
      widget.registry.background.forgetAll().catchError((Object _) {});
    }
    super.dispose();
  }

  Future<void> _continue() async {
    final allowed = await widget.registry.notifier.requestPermission();
    if (!mounted) return;
    setState(() {
      _denied = !allowed;
      _choosing = allowed;
    });
  }

  Future<void> _turnOn() async {
    if (!widget.desktop) {
      await widget.registry.setBackgroundChecks(on: true);
    }
    _done = true;
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final phone = context.isPhoneWidth;
    final title = widget.desktop ? l.keepSyncingWindowLabel : l.checksLabel;

    final List<Widget> body;
    if (widget.desktop) {
      body = [
        for (final line in [
          l.keepSyncingWindowHelp,
          l.keepSyncingConsentRisk,
          l.keepSyncingConsentQuit,
          l.keepSyncingConsentCost,
        ]) ...[
          Text(line, style: text.bodyMedium),
          const SizedBox(height: KnSpace.sm),
        ],
        const SizedBox(height: KnSpace.md),
        _actions(l, KnButton.primary(l.checksTurnOnAction, onPressed: _turnOn)),
      ];
    } else if (!_choosing) {
      body = [
        for (final line in [
          l.checksExplainWhat,
          l.checksExplainKey,
          l.checksExplainSeed,
          l.checksExplainCost,
          l.checksExplainOff,
        ]) ...[
          Text(line, style: text.bodyMedium),
          const SizedBox(height: KnSpace.sm),
        ],
        if (_denied) ...[
          const SizedBox(height: KnSpace.sm),
          ErrorLine(l.checksNeedNotifications),
        ],
        const SizedBox(height: KnSpace.md),
        _actions(l, KnButton.primary(l.continueAction, onPressed: _continue)),
      ];
    } else {
      body = [
        Eyebrow(l.checksWalletsRow),
        const SizedBox(height: KnSpace.sm),
        Text(l.checksChooseHelp, style: text.bodyMedium),
        const SizedBox(height: KnSpace.md),
        BackgroundWalletList(
          registry: widget.registry,
          onChanged: (chosen) => setState(() => _chosen = chosen),
        ),
        const SizedBox(height: KnSpace.lg),
        BatteryNote(registry: widget.registry),
        const SizedBox(height: KnSpace.lg),
        _actions(
          l,
          KnButton.primary(
            l.checksTurnOnAction,
            onPressed: _chosen.isEmpty ? null : _turnOn,
          ),
        ),
      ];
    }

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: EdgeInsets.all(phone ? KnSpace.md : KnSpace.xl),
            children: body,
          ),
        ),
      ),
    );
  }

  Widget _actions(AppLocalizations l, Widget primary) => Wrap(
    spacing: KnSpace.sm,
    runSpacing: KnSpace.sm,
    children: [
      primary,
      KnButton.text(
        l.cancelAction,
        onPressed: () => Navigator.of(context).pop(false),
      ),
    ],
  );
}

/// The wallets background checks can look at, each with a switch. Turning
/// one on asks for its password; turning it off deletes what was kept for
/// it. [onChanged] gets the ids being checked after every change.
class BackgroundWalletList extends StatefulWidget {
  const BackgroundWalletList({
    super.key,
    required this.registry,
    this.onChanged,
  });

  final WalletRegistry registry;
  final ValueChanged<Set<String>>? onChanged;

  @override
  State<BackgroundWalletList> createState() => _BackgroundWalletListState();
}

class _BackgroundWalletListState extends State<BackgroundWalletList> {
  Set<String> _checked = const {};
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final ids = await widget.registry.checkedWallets();
    if (!mounted) return;
    setState(() => _checked = ids.toSet());
    widget.onChanged?.call(_checked);
  }

  Future<void> _toggle(WalletSummary wallet, bool on) async {
    setState(() => _error = null);
    if (on) {
      final added = await showDialog<bool>(
        context: context,
        builder: (_) =>
            _CheckPasswordDialog(registry: widget.registry, wallet: wallet),
      );
      if (added != true) return;
    } else {
      try {
        await widget.registry.stopCheckingWallet(wallet.id);
      } on PlatformException {
        if (mounted) {
          setState(
            () => _error = AppLocalizations.of(context).checksSaveFailed,
          );
        }
      }
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final wallets = widget.registry.all.where((w) => !w.cold).toList();
    if (wallets.isEmpty) {
      return Text(l.checksNoWallets, style: text.bodyMedium);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        KnCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: withDividers([
              for (final w in wallets)
                KnRow(
                  title: Text(w.name),
                  subtitle: Text(w.network.label(context)),
                  trailing: Switch(
                    value: _checked.contains(w.id),
                    onChanged: (on) => _toggle(w, on),
                  ),
                ),
            ]),
          ),
        ),
        if (_error case final error?) ...[
          const SizedBox(height: KnSpace.md),
          ErrorLine(error),
        ],
      ],
    );
  }
}

/// Why checks may run late, and the way to the system's battery settings.
class BatteryNote extends StatefulWidget {
  const BatteryNote({super.key, required this.registry});

  final WalletRegistry registry;

  @override
  State<BatteryNote> createState() => _BatteryNoteState();
}

class _BatteryNoteState extends State<BatteryNote> with WidgetsBindingObserver {
  bool _unrestricted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Back from the system settings: show what the owner chose there.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    try {
      final unrestricted = await widget.registry.background
          .batteryUnrestricted();
      if (mounted) setState(() => _unrestricted = unrestricted);
    } on Object {
      // Unknown; the note stays.
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Eyebrow(l.checksBatteryEyebrow),
        const SizedBox(height: KnSpace.sm),
        Text(
          _unrestricted ? l.checksBatteryUnrestricted : l.checksBatteryHelp,
          style: text.bodyMedium,
        ),
        if (!_unrestricted)
          KnButton.text(
            l.checksBatteryAction,
            onPressed: () => widget.registry.background
                .openBatterySettings()
                .catchError((Object _) => false),
          ),
      ],
    );
  }
}

/// Asks for a wallet's password and starts checking it. Pops `true` once
/// it is checked.
class _CheckPasswordDialog extends StatefulWidget {
  const _CheckPasswordDialog({required this.registry, required this.wallet});

  final WalletRegistry registry;
  final WalletSummary wallet;

  @override
  State<_CheckPasswordDialog> createState() => _CheckPasswordDialogState();
}

class _CheckPasswordDialogState extends State<_CheckPasswordDialog> {
  final _password = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    if (_busy) return;
    final l = AppLocalizations.of(context);
    setState(() => _busy = true);
    String? error;
    try {
      await widget.registry.checkWallet(widget.wallet.id, _password.text);
    } on BackgroundError catch (e) {
      error = switch (e) {
        BackgroundError.wrongPassword => l.errorWrongPassword,
        BackgroundError.cold => l.checksColdWallet,
        BackgroundError.lwsConsentNeeded => l.checksLwsConsent,
        _ => l.checksSaveFailed,
      };
    } on PlatformException {
      error = l.checksSaveFailed;
    }
    if (!mounted) return;
    if (error == null) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _busy = false;
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l.checksPasswordTitle(widget.wallet.name)),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l.checksPasswordPrompt),
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
          onPressed: () => Navigator.of(context).pop(false),
        ),
        KnButton.primary(l.continueAction, onPressed: _busy ? null : _confirm),
      ],
    );
  }
}

/// Settings for checks that are on: which wallets, and battery.
class BackgroundWalletsScreen extends StatelessWidget {
  const BackgroundWalletsScreen({super.key, required this.registry});

  final WalletRegistry registry;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final phone = context.isPhoneWidth;
    return Scaffold(
      appBar: AppBar(title: Text(l.checksWalletsRow)),
      body: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: EdgeInsets.all(phone ? KnSpace.md : KnSpace.xl),
            children: [
              Text(l.checksChooseHelp, style: text.bodyMedium),
              const SizedBox(height: KnSpace.md),
              // Removing the last wallet turns checks off.
              BackgroundWalletList(registry: registry),
              const SizedBox(height: KnSpace.lg),
              BatteryNote(registry: registry),
            ],
          ),
        ),
      ),
    );
  }
}
