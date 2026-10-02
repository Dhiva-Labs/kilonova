import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../src/rust/api/nodes.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import 'nodes_screen.dart' show nodeErrorMessage;

/// Tor's SOCKS port as Orbot and the Tor daemon open it.
const _torDefault = '127.0.0.1:9050';

/// Send all traffic through a SOCKS5 proxy such as Tor.
class ProxyScreen extends StatefulWidget {
  const ProxyScreen({super.key});

  @override
  State<ProxyScreen> createState() => _ProxyScreenState();
}

class _ProxyScreenState extends State<ProxyScreen> {
  final _url = TextEditingController();
  String? _saved;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    networkProxy().then((saved) {
      if (!mounted) return;
      setState(() {
        _saved = saved;
        _url.text = saved ?? '';
      });
    });
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

    return Scaffold(
      appBar: AppBar(title: Text(l.proxyTitle)),
      body: ListView(
        padding: const EdgeInsets.all(KnSpace.lg),
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l.proxyHelp, style: text.bodyMedium),
                const SizedBox(height: KnSpace.sm),
                Text(l.proxyTorHelp, style: text.bodySmall),
                const SizedBox(height: KnSpace.lg),
                Text(
                  saved == null ? l.proxyOff : l.proxyOn(saved),
                  style: saved == null
                      ? text.bodyMedium
                      : text.bodyMedium!.copyWith(color: c.received),
                ),
                const SizedBox(height: KnSpace.md),
                TextField(
                  controller: _url,
                  enabled: !_busy,
                  autocorrect: false,
                  style: monoStyle(context, size: 14),
                  decoration: InputDecoration(
                    labelText: l.proxyField,
                    hintText: _torDefault,
                    errorText: _error,
                  ),
                  onSubmitted: (_) => _save(),
                ),
                const SizedBox(height: KnSpace.md),
                Wrap(
                  spacing: KnSpace.sm,
                  runSpacing: KnSpace.sm,
                  children: [
                    FilledButton(
                      onPressed: _busy ? null : _save,
                      child: Text(l.proxySaveAction),
                    ),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => setState(() => _url.text = _torDefault),
                      child: Text(l.proxyUseTorAction),
                    ),
                    if (saved != null)
                      TextButton(
                        onPressed: _busy ? null : _turnOff,
                        child: Text(l.proxyOffAction),
                      ),
                  ],
                ),
                if (_error == null && _busy) ...[
                  const SizedBox(height: KnSpace.sm),
                  Text(l.proxyChecking, style: text.bodySmall),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
