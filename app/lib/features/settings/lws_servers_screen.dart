import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../src/rust/api/network.dart';
import '../../src/rust/api/nodes.dart';
import '../../src/rust/api/preferences.dart' as prefs_api;
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/copy_value.dart';
import '../../widgets/error_line.dart';
import '../../widgets/kn_button.dart';
import '../../widgets/kn_card.dart';
import '../../widgets/kn_field.dart';
import '../../widgets/kn_segments.dart';
import '../../widgets/network_label.dart';
import '../wallets/wallet_registry.dart';
import 'certificate_dialog.dart';
import 'nodes_screen.dart' show nodeErrorMessage;

/// Choose the light wallet server for each network. There is no default.
class LwsServersScreen extends StatefulWidget {
  const LwsServersScreen({
    super.key,
    this.initialNetwork = Network.mainnet,
    this.registry,
  });

  final Network initialNetwork;

  /// Updated after saving `confirmLwsPayments`, when the caller has one.
  final WalletRegistry? registry;

  @override
  State<LwsServersScreen> createState() => _LwsServersScreenState();
}

class _LwsServersScreenState extends State<LwsServersScreen> {
  late var _network = widget.initialNetwork;
  final _url = TextEditingController();
  String? _saved;
  String? _error;
  String? _health;
  prefs_api.Preferences? _prefs;

  @override
  void initState() {
    super.initState();
    _load();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final loaded =
        widget.registry?.preferences ?? await prefs_api.preferences();
    if (mounted) setState(() => _prefs = loaded);
  }

  Future<void> _setConfirmLwsPayments(bool on) async {
    final current = _prefs;
    if (current == null) return;
    final next = prefs_api.Preferences(
      notifyIncoming: current.notifyIncoming,
      backgroundSync: current.backgroundSync,
      confirmLwsPayments: on,
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

  Future<void> _load() async {
    final saved = await lwsServer(network: _network);
    if (!mounted) return;
    setState(() {
      _saved = saved;
      _url.text = saved ?? '';
      _error = null;
      _health = null;
    });
  }

  Future<void> _save() async {
    final l = AppLocalizations.of(context);
    setState(() {
      _error = null;
      _health = null;
    });
    try {
      final url = await setLwsServer(network: _network, url: _url.text);
      setState(() {
        _saved = url;
        _url.text = url;
      });
      final health = await checkLwsServer(network: _network, url: url);
      if (!mounted) return;
      setState(
        () => _health = health.serverType == null
            ? l.lwsHealthy(health.height.toString())
            : l.lwsHealthyType(health.serverType!, health.height.toString()),
      );
    } on NodeError catch (e) {
      if (e == NodeError.untrustedCertificate &&
          mounted &&
          await offerToTrustCertificate(context, _url.text)) {
        return _save();
      }
      if (mounted) setState(() => _error = nodeErrorMessage(context, e));
    }
  }

  Future<void> _clear() async {
    await clearLwsServer(network: _network);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final c = context.kn;
    final phone = context.isPhoneWidth;

    return Scaffold(
      appBar: AppBar(title: Text(l.lwsTitle)),
      body: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: EdgeInsets.all(phone ? KnSpace.md : KnSpace.xl),
            children: [
              Text(l.lwsHelp, style: text.bodyMedium),
              const SizedBox(height: KnSpace.lg),
              KnSegments<Network>(
                segments: [
                  for (final n in allNetworks()) KnSegment(n, n.label(context)),
                ],
                selected: _network,
                onChanged: (n) {
                  setState(() => _network = n);
                  _load();
                },
              ),
              const SizedBox(height: KnSpace.lg),
              KnField(
                controller: _url,
                label: l.lwsServerLabel,
                onSubmitted: (_) => _save(),
                trailing: [PasteButton(controller: _url)],
              ),
              const SizedBox(height: KnSpace.md),
              KnCard(
                child: KnRow(
                  padding: EdgeInsets.zero,
                  title: Text(l.confirmLwsPaymentsTitle),
                  subtitle: Text(l.confirmLwsPaymentsSubtitle),
                  trailing: Switch(
                    value: _prefs?.confirmLwsPayments ?? false,
                    onChanged: _prefs == null ? null : _setConfirmLwsPayments,
                  ),
                ),
              ),
              const SizedBox(height: KnSpace.md),
              Wrap(
                spacing: KnSpace.sm,
                runSpacing: KnSpace.sm,
                children: [
                  KnButton.primary(l.lwsSaveAction, onPressed: _save),
                  if (_saved != null)
                    KnButton.text(l.lwsClearAction, onPressed: _clear),
                ],
              ),
              const SizedBox(height: KnSpace.md),
              if (_error != null) ErrorLine(_error!),
              if (_health != null)
                Text(
                  _health!,
                  style: text.bodyMedium!.copyWith(color: c.received),
                ),
              if (_saved == null && _error == null)
                Text(l.lwsNotSet, style: text.bodySmall),
            ],
          ),
        ),
      ),
    );
  }
}
