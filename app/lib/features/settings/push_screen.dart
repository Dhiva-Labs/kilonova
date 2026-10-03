import 'dart:io';

import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../platform/push.dart';
import '../../src/rust/api/push.dart';
import '../../src/rust/api/wallets.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/copy_value.dart';
import '../../widgets/error_line.dart';
import '../../widgets/kn_button.dart';
import '../../widgets/kn_card.dart';
import '../../widgets/kn_field.dart';
import '../../widgets/network_label.dart';
import '../send/scan_qr.dart';
import '../wallets/wallet_registry.dart';
import 'proxy_screen.dart';

/// Payment pushes from the owner's own server, per wallet (see
/// `tools/selfhost/push-register`). Only LWS-mode wallets: the server only
/// sees payments to wallets it scans.
class PushScreen extends StatefulWidget {
  const PushScreen({super.key, required this.registry});

  final WalletRegistry registry;

  @override
  State<PushScreen> createState() => _PushScreenState();
}

class _PushScreenState extends State<PushScreen> {
  Map<String, PushSubscription> _subscriptions = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final all = await pushSubscriptions();
    if (mounted) {
      setState(() => _subscriptions = {for (final s in all) s.walletId: s});
    }
  }

  Future<void> _open(WalletSummary wallet) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PushWalletScreen(
          registry: widget.registry,
          wallet: wallet,
          subscription: _subscriptions[wallet.id],
        ),
      ),
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final phone = context.isPhoneWidth;
    final wallets = widget.registry.all
        .where((w) => w.mode == SyncMode.lws && !w.cold)
        .toList();

    return Scaffold(
      appBar: AppBar(title: Text(l.pushRow)),
      body: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: EdgeInsets.all(phone ? KnSpace.md : KnSpace.xl),
            children: [
              Text(l.pushExplain, style: text.bodyMedium),
              const SizedBox(height: KnSpace.sm),
              Text(
                Platform.isAndroid ? l.pushAndroidNote : l.pushDesktopNote,
                style: text.bodyMedium,
              ),
              const SizedBox(height: KnSpace.lg),
              if (wallets.isEmpty)
                Text(l.pushNoWallets, style: text.bodyMedium)
              else
                ValueListenableBuilder(
                  valueListenable: widget.registry.push.states,
                  builder: (context, states, _) => KnCard(
                    padding: EdgeInsets.zero,
                    child: Column(
                      children: withDividers([
                        for (final w in wallets)
                          KnRow(
                            title: Text(w.name),
                            subtitle: Text(
                              '${w.network.label(context)} · '
                              '${pushStateLabel(context, _subscriptions.containsKey(w.id) ? states[w.id] ?? PushState.ready : null)}',
                            ),
                            onTap: () => _open(w),
                          ),
                      ]),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// What a wallet's push state says; `null` means off.
String pushStateLabel(BuildContext context, PushState? state) {
  final l = AppLocalizations.of(context);
  return switch (state) {
    null => l.pushStateOff,
    PushState.ready => l.pushStateOn,
    PushState.waiting => l.pushStateWaiting,
    PushState.noDistributor => l.pushStateNoDistributor,
    PushState.wrongServer => l.pushStateWrongServer,
    PushState.unreachable => l.pushStateUnreachable,
  };
}

/// Turns pushes on or off for one wallet.
class PushWalletScreen extends StatefulWidget {
  const PushWalletScreen({
    super.key,
    required this.registry,
    required this.wallet,
    this.subscription,
  });

  final WalletRegistry registry;
  final WalletSummary wallet;
  final PushSubscription? subscription;

  @override
  State<PushWalletScreen> createState() => _PushWalletScreenState();
}

class _PushWalletScreenState extends State<PushWalletScreen> {
  final _code = TextEditingController();
  late PushSubscription? _subscription = widget.subscription;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _turnOn(String code) async {
    if (code.trim().isEmpty) return;
    final l = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.registry.notifier.requestPermission();
      final sub = await setPushSubscription(
        walletId: widget.wallet.id,
        network: widget.wallet.network,
        code: code.trim(),
      );
      await widget.registry.push.subscribe(
        sub,
        title: l.pushArrivedTitle(widget.wallet.name),
        body: l.pushArrivedBody,
      );
      if (mounted) setState(() => _subscription = sub);
    } on PushError catch (e) {
      if (mounted) {
        setState(() {
          _error = switch (e) {
            PushError.badCode => l.pushBadCode,
            PushError.noServer => l.pushNoServer,
            _ => l.pushCannotSave,
          };
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _turnOff() async {
    setState(() => _busy = true);
    try {
      await widget.registry.push.unsubscribe(widget.wallet.id);
      await removePushSubscription(walletId: widget.wallet.id);
      if (mounted) setState(() => _subscription = null);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _scan() async {
    final text = await scanQr(context);
    if (text == null || !mounted) return;
    await _turnOn(text);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final phone = context.isPhoneWidth;
    final sub = _subscription;

    return Scaffold(
      appBar: AppBar(title: Text(widget.wallet.name)),
      body: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: EdgeInsets.all(phone ? KnSpace.md : KnSpace.xl),
            children: [
              if (sub == null) ...[
                Text(l.pushWalletExplain, style: text.bodyMedium),
                const SizedBox(height: KnSpace.lg),
                KnButton.primary(
                  l.pushScanAction,
                  onPressed: _busy ? null : _scan,
                  expand: true,
                ),
                const SizedBox(height: KnSpace.lg),
                KnField(
                  controller: _code,
                  label: l.pushPasteField,
                  mono: true,
                  multiline: true,
                  enabled: !_busy,
                  onSubmitted: _turnOn,
                  trailing: [PasteButton(controller: _code)],
                ),
                const SizedBox(height: KnSpace.sm),
                KnButton.secondary(
                  l.pushTurnOnAction,
                  onPressed: _busy ? null : () => _turnOn(_code.text),
                ),
              ] else ...[
                ValueListenableBuilder(
                  valueListenable: widget.registry.push.states,
                  builder: (context, states, _) {
                    final state = states[sub.walletId] ?? PushState.ready;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        KnCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: withDividers([
                              KeyValue(
                                label: l.pushStatusLabel,
                                value: Text(pushStateLabel(context, state)),
                              ),
                              CopyValue(
                                label: l.pairServerServerLabel,
                                value: sub.server,
                              ),
                            ]),
                          ),
                        ),
                        if (state == PushState.unreachable)
                          KnButton.text(
                            l.pairServerProxyAction,
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => const ProxyScreen(),
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: KnSpace.md),
                Align(
                  alignment: Alignment.centerLeft,
                  child: KnButton.secondary(
                    l.pushTurnOffAction,
                    onPressed: _busy ? null : _turnOff,
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: KnSpace.md),
                ErrorLine(_error!),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
