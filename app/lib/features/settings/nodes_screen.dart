import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../src/rust/api/network.dart';
import '../../src/rust/api/nodes.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/error_line.dart';
import '../../widgets/network_label.dart';

String nodeErrorMessage(BuildContext context, NodeError error) {
  final l = AppLocalizations.of(context);
  return switch (error) {
    NodeError.badUrl => l.nodeErrorBadUrl,
    NodeError.wrongNetwork => l.nodeErrorWrongNetwork,
    NodeError.unreachable => l.nodeErrorUnreachable,
    NodeError.storage || NodeError.notInitialized => l.nodeErrorStorage,
  };
}

/// Choose which node each network syncs from, and add your own.
class NodesScreen extends StatefulWidget {
  const NodesScreen({super.key});

  @override
  State<NodesScreen> createState() => _NodesScreenState();
}

class _NodesScreenState extends State<NodesScreen> {
  var _network = Network.mainnet;
  List<NodeChoice> _nodes = const [];
  final _add = TextEditingController();
  String? _addError;
  final Map<String, String> _health = {};
  final Map<String, String> _healthErrors = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _add.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final list = await nodes(network: _network);
    if (mounted) setState(() => _nodes = list);
  }

  Future<void> _addNode() async {
    try {
      await addNode(network: _network, url: _add.text);
      _add.clear();
      setState(() => _addError = null);
      await _load();
    } on NodeError catch (e) {
      if (mounted) setState(() => _addError = nodeErrorMessage(context, e));
    }
  }

  Future<void> _check(String url) async {
    final l = AppLocalizations.of(context);
    setState(() {
      _health.remove(url);
      _healthErrors.remove(url);
    });
    try {
      final h = await checkNode(network: _network, url: url);
      if (!mounted) return;
      setState(
        () => _health[url] = h.synced
            ? l.nodesHealthy(h.height.toString())
            : l.nodesBehind(h.height.toString()),
      );
    } on NodeError catch (e) {
      if (mounted) {
        setState(() => _healthErrors[url] = nodeErrorMessage(context, e));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final c = context.kn;
    final selected = _nodes.where((n) => n.selected).firstOrNull?.url;

    return Scaffold(
      appBar: AppBar(title: Text(l.nodesTitle)),
      body: ListView(
        padding: const EdgeInsets.all(KnSpace.lg),
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l.nodesHelp, style: text.bodyMedium),
                const SizedBox(height: KnSpace.lg),
                SegmentedButton<Network>(
                  showSelectedIcon: false,
                  segments: [
                    for (final n in allNetworks())
                      ButtonSegment(value: n, label: Text(n.label(context))),
                  ],
                  selected: {_network},
                  onSelectionChanged: (s) {
                    setState(() {
                      _network = s.single;
                      _health.clear();
                      _healthErrors.clear();
                    });
                    _load();
                  },
                ),
                const SizedBox(height: KnSpace.lg),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _add,
                        autocorrect: false,
                        decoration: InputDecoration(
                          labelText: l.nodesAddLabel,
                          errorText: _addError,
                        ),
                        onSubmitted: (_) => _addNode(),
                      ),
                    ),
                    const SizedBox(width: KnSpace.sm),
                    Padding(
                      padding: const EdgeInsets.only(top: KnSpace.xs),
                      child: FilledButton(
                        onPressed: _addNode,
                        child: Text(l.nodesAddAction),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: KnSpace.lg),
                const Divider(),
                RadioGroup<String>(
                  groupValue: selected,
                  onChanged: (url) async {
                    if (url == null) return;
                    await selectNode(network: _network, url: url);
                    await _load();
                  },
                  child: Column(
                    children: [
                      for (final node in _nodes) ...[
                        RadioListTile<String>(
                          value: node.url,
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            node.url,
                            style: monoStyle(context, size: 14),
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                node.bundled
                                    ? l.nodesBundledTag
                                    : l.nodesCustomTag,
                                style: text.bodySmall,
                              ),
                              if (_health[node.url] != null)
                                Text(
                                  _health[node.url]!,
                                  style: text.bodySmall!.copyWith(
                                    color: c.received,
                                  ),
                                ),
                              if (_healthErrors[node.url] != null)
                                ErrorLine(_healthErrors[node.url]!),
                            ],
                          ),
                          secondary: Wrap(
                            children: [
                              TextButton(
                                onPressed: () => _check(node.url),
                                child: Text(l.nodesCheckAction),
                              ),
                              if (!node.bundled)
                                TextButton(
                                  onPressed: () async {
                                    await removeNode(
                                      network: _network,
                                      url: node.url,
                                    );
                                    await _load();
                                  },
                                  child: Text(l.nodesRemoveAction),
                                ),
                            ],
                          ),
                        ),
                        const Divider(),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
