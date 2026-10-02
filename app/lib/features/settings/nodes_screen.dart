import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../src/rust/api/network.dart';
import '../../src/rust/api/nodes.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/error_line.dart';
import '../../widgets/kn_button.dart';
import '../../widgets/kn_card.dart';
import '../../widgets/kn_field.dart';
import '../../widgets/kn_segments.dart';
import 'certificate_dialog.dart';
import '../../widgets/network_label.dart';

String nodeErrorMessage(BuildContext context, NodeError error) {
  final l = AppLocalizations.of(context);
  return switch (error) {
    NodeError.badUrl => l.nodeErrorBadUrl,
    NodeError.wrongNetwork => l.nodeErrorWrongNetwork,
    NodeError.unreachable => l.nodeErrorUnreachable,
    NodeError.storage || NodeError.notInitialized => l.nodeErrorStorage,
    NodeError.badProxy => l.nodeErrorBadProxy,
    NodeError.needsTor => l.nodeErrorNeedsTor,
    NodeError.untrustedCertificate => l.nodeErrorUntrustedCertificate,
    NodeError.insecureLws => l.nodeErrorInsecureLws,
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
      if (e == NodeError.untrustedCertificate &&
          mounted &&
          await offerToTrustCertificate(context, url)) {
        await _load();
        return _check(url);
      }
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
    final phone = context.isPhoneWidth;

    return Scaffold(
      appBar: AppBar(title: Text(l.nodesTitle)),
      body: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: EdgeInsets.all(phone ? KnSpace.md : KnSpace.xl),
            children: [
              Text(l.nodesHelp, style: text.bodyMedium),
              const SizedBox(height: KnSpace.lg),
              KnSegments<Network>(
                segments: [
                  for (final n in allNetworks()) KnSegment(n, n.label(context)),
                ],
                selected: _network,
                onChanged: (n) {
                  setState(() {
                    _network = n;
                    _health.clear();
                    _healthErrors.clear();
                  });
                  _load();
                },
              ),
              const SizedBox(height: KnSpace.lg),
              Flex(
                direction: phone ? Axis.vertical : Axis.horizontal,
                crossAxisAlignment: phone
                    ? CrossAxisAlignment.stretch
                    : CrossAxisAlignment.end,
                children: [
                  phone
                      ? KnField(
                          controller: _add,
                          label: l.nodesAddLabel,
                          error: _addError,
                          onSubmitted: (_) => _addNode(),
                        )
                      : Expanded(
                          child: KnField(
                            controller: _add,
                            label: l.nodesAddLabel,
                            error: _addError,
                            onSubmitted: (_) => _addNode(),
                          ),
                        ),
                  SizedBox(
                    width: phone ? 0 : KnSpace.sm,
                    height: phone ? KnSpace.sm : 0,
                  ),
                  KnButton.primary(
                    l.nodesAddAction,
                    onPressed: _addNode,
                    expand: phone,
                  ),
                ],
              ),
              const SizedBox(height: KnSpace.lg),
              KnCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: withDividers([
                    for (final node in _nodes)
                      KnRow(
                        selected: node.url == selected,
                        onTap: () async {
                          await selectNode(network: _network, url: node.url);
                          await _load();
                        },
                        title: Text(
                          node.url,
                          style: monoStyle(context, size: 14),
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              [
                                node.bundled
                                    ? l.nodesBundledTag
                                    : l.nodesCustomTag,
                                if (node.pinned) l.nodesPinnedTag,
                              ].join(' · '),
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
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            KnButton.text(
                              l.nodesCheckAction,
                              onPressed: () => _check(node.url),
                            ),
                            if (!node.bundled)
                              KnButton.text(
                                l.nodesRemoveAction,
                                onPressed: () async {
                                  await removeNode(
                                    network: _network,
                                    url: node.url,
                                  );
                                  await _load();
                                },
                              ),
                          ],
                        ),
                      ),
                  ]),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
