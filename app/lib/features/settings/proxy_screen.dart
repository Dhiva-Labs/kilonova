import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../src/rust/api/nodes.dart';
import '../../src/rust/api/preferences.dart' as prefs_api;
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/kn_button.dart';
import '../../widgets/kn_card.dart';
import '../../widgets/kn_field.dart';
import '../wallets/wallet_registry.dart';
import 'nodes_screen.dart' show nodeErrorMessage;

/// Tor's SOCKS port as Orbot and the Tor daemon open it.
const _torDefault = '127.0.0.1:9050';

/// Send all traffic through a SOCKS5 proxy such as Tor.
class ProxyScreen extends StatefulWidget {
  const ProxyScreen({super.key, this.registry});

  /// Updated after saving `broadcastElsewhere`, when the caller has one.
  final WalletRegistry? registry;

  @override
  State<ProxyScreen> createState() => _ProxyScreenState();
}

class _ProxyScreenState extends State<ProxyScreen> {
  final _url = TextEditingController();
  String? _saved;
  String? _error;
  bool _busy = false;
  prefs_api.Preferences? _prefs;

  @override
  void initState() {
    super.initState();
    _loadPrefs();
    networkProxy().then((saved) {
      if (!mounted) return;
      setState(() {
        _saved = saved;
        _url.text = saved ?? '';
      });
    });
  }

  Future<void> _loadPrefs() async {
    final loaded =
        widget.registry?.preferences ?? await prefs_api.preferences();
    if (mounted) setState(() => _prefs = loaded);
  }

  Future<void> _setBroadcastElsewhere(bool on) async {
    final current = _prefs;
    if (current == null) return;
    final next = prefs_api.Preferences(
      notifyIncoming: current.notifyIncoming,
      backgroundSync: current.backgroundSync,
      confirmLwsPayments: current.confirmLwsPayments,
      broadcastElsewhere: on,
    );
    await prefs_api.setPreferences(preferences: next);
    widget.registry?.preferences = next;
    if (mounted) setState(() => _prefs = next);
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // Only a proxy that answers is saved: a dead one would stop all sync.
      await checkNetworkProxy(url: _url.text);
      final saved = await setNetworkProxy(url: _url.text);
      if (!mounted) return;
      setState(() {
        _saved = saved;
        _url.text = saved ?? '';
      });
    } on NodeError catch (e) {
      if (mounted) setState(() => _error = nodeErrorMessage(context, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _turnOff() async {
    await setNetworkProxy(url: null);
    if (!mounted) return;
    setState(() {
      _saved = null;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final c = context.kn;
    final saved = _saved;
    final phone = context.isPhoneWidth;

    return Scaffold(
      appBar: AppBar(title: Text(l.proxyTitle)),
      body: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: EdgeInsets.all(phone ? KnSpace.md : KnSpace.xl),
            children: [
              Text(l.proxyHelp, style: text.bodyMedium),
              const SizedBox(height: KnSpace.sm),
              Text(l.proxyTorHelp, style: text.bodySmall),
              const SizedBox(height: KnSpace.sm),
              Text(l.proxyCircuitHelp, style: text.bodySmall),
              const SizedBox(height: KnSpace.lg),
              Text(
                saved == null ? l.proxyOff : l.proxyOn(saved),
                style: saved == null
                    ? text.bodyMedium
                    : text.bodyMedium!.copyWith(color: c.received),
              ),
              const SizedBox(height: KnSpace.md),
              KnField(
                controller: _url,
                enabled: !_busy,
                mono: true,
                label: l.proxyField,
                hint: _torDefault,
                error: _error,
                onSubmitted: (_) => _save(),
              ),
              const SizedBox(height: KnSpace.md),
              Wrap(
                spacing: KnSpace.sm,
                runSpacing: KnSpace.sm,
                children: [
                  KnButton.primary(
                    l.proxySaveAction,
                    onPressed: _busy ? null : _save,
                  ),
                  KnButton.text(
                    l.proxyUseTorAction,
                    onPressed: _busy
                        ? null
                        : () => setState(() => _url.text = _torDefault),
                  ),
                  if (saved != null)
                    KnButton.text(
                      l.proxyOffAction,
                      onPressed: _busy ? null : _turnOff,
                    ),
                ],
              ),
              if (_error == null && _busy) ...[
                const SizedBox(height: KnSpace.sm),
                Text(l.proxyChecking, style: text.bodySmall),
              ],
              const SizedBox(height: KnSpace.lg),
              KnCard(
                child: KnRow(
                  padding: EdgeInsets.zero,
                  title: Text(l.broadcastElsewhereTitle),
                  subtitle: Text(l.broadcastElsewhereSubtitle),
                  trailing: Switch(
                    value: _prefs?.broadcastElsewhere ?? true,
                    onChanged: _prefs == null ? null : _setBroadcastElsewhere,
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
