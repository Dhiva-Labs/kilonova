import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../src/rust/api/network.dart';
import '../../src/rust/api/nodes.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/error_line.dart';
import '../../widgets/network_label.dart';
import 'certificate_dialog.dart';
import 'nodes_screen.dart' show nodeErrorMessage;

/// Choose the light wallet server for each network. There is no default.
class LwsServersScreen extends StatefulWidget {
  const LwsServersScreen({super.key, this.initialNetwork = Network.mainnet});

  final Network initialNetwork;

  @override
  State<LwsServersScreen> createState() => _LwsServersScreenState();
}

class _LwsServersScreenState extends State<LwsServersScreen> {
  late var _network = widget.initialNetwork;
  final _url = TextEditingController();
  String? _saved;
  String? _error;
  String? _health;

  @override
  void initState() {
    super.initState();
    _load();
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

    return Scaffold(
      appBar: AppBar(title: Text(l.lwsTitle)),
      body: ListView(
        padding: const EdgeInsets.all(KnSpace.lg),
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l.lwsHelp, style: text.bodyMedium),
                const SizedBox(height: KnSpace.lg),
                SegmentedButton<Network>(
                  showSelectedIcon: false,
                  segments: [
                    for (final n in allNetworks())
                      ButtonSegment(value: n, label: Text(n.label(context))),
                  ],
                  selected: {_network},
                  onSelectionChanged: (s) {
                    setState(() => _network = s.single);
                    _load();
                  },
                ),
                const SizedBox(height: KnSpace.lg),
                TextField(
                  controller: _url,
                  autocorrect: false,
                  decoration: InputDecoration(labelText: l.lwsServerLabel),
                  onSubmitted: (_) => _save(),
                ),
                const SizedBox(height: KnSpace.md),
                Row(
                  children: [
                    FilledButton(
                      onPressed: _save,
                      child: Text(l.lwsSaveAction),
                    ),
                    const SizedBox(width: KnSpace.sm),
                    if (_saved != null)
                      TextButton(
                        onPressed: _clear,
                        child: Text(l.lwsClearAction),
                      ),
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
        ],
      ),
    );
  }
}
