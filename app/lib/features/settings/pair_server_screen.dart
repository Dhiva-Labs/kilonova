import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../src/rust/api/nodes.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/copy_value.dart';
import '../../widgets/error_line.dart';
import '../../widgets/kn_button.dart';
import '../../widgets/kn_card.dart';
import '../../widgets/kn_field.dart';
import '../../widgets/network_label.dart';
import '../send/scan_qr.dart';
import 'nodes_screen.dart' show nodeErrorMessage;
import 'proxy_screen.dart';

/// Pairs with a self-hosted node and light wallet server from one code,
/// printed by `tools/selfhost`.
class PairServerScreen extends StatefulWidget {
  const PairServerScreen({super.key});

  @override
  State<PairServerScreen> createState() => _PairServerScreenState();
}

class _PairServerScreenState extends State<PairServerScreen> {
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;
  ServerPaired? _result;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _pair(String code) async {
    if (code.trim().isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await pairWithServer(code: code.trim());
      if (mounted) setState(() => _result = result);
    } on NodeError catch (e) {
      if (mounted) setState(() => _error = nodeErrorMessage(context, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _scan() async {
    final text = await scanQr(context);
    if (text == null || !mounted) return;
    await _pair(text);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final phone = context.isPhoneWidth;
    final result = _result;

    return Scaffold(
      appBar: AppBar(title: Text(l.pairServerRow)),
      body: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: EdgeInsets.all(phone ? KnSpace.md : KnSpace.xl),
            children: [
              Text(l.pairServerExplain, style: text.bodyMedium),
              const SizedBox(height: KnSpace.lg),
              KnButton.primary(
                l.pairServerScanAction,
                onPressed: _busy ? null : _scan,
                expand: true,
              ),
              const SizedBox(height: KnSpace.lg),
              KnField(
                controller: _code,
                label: l.pairServerPasteField,
                mono: true,
                multiline: true,
                enabled: !_busy,
                onSubmitted: _pair,
                trailing: [PasteButton(controller: _code)],
              ),
              const SizedBox(height: KnSpace.sm),
              KnButton.secondary(
                l.pairServerPairAction,
                onPressed: _busy ? null : () => _pair(_code.text),
              ),
              if (_error != null) ...[
                const SizedBox(height: KnSpace.md),
                ErrorLine(_error!),
              ],
              if (result != null) ...[
                const SizedBox(height: KnSpace.lg),
                KnCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: withDividers([
                      KeyValue(
                        label: l.pairServerNetworkLabel,
                        value: Text(result.network.label(context)),
                      ),
                      if (result.node != null)
                        KeyValue(
                          label: l.pairServerNodeLabel,
                          value: Text(result.node!),
                        ),
                      if (result.lws != null)
                        KeyValue(
                          label: l.pairServerServerLabel,
                          value: Text(result.lws!),
                        ),
                      if (result.push != null)
                        KeyValue(
                          label: l.pairServerPushLabel,
                          value: Text(result.push!),
                        ),
                    ]),
                  ),
                ),
                if (result.needsTor) ...[
                  const SizedBox(height: KnSpace.md),
                  KnCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(l.pairServerNeedsTorTitle, style: text.bodyMedium),
                        const SizedBox(height: KnSpace.sm),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: KnButton.text(
                            l.pairServerProxyAction,
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => const ProxyScreen(),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}
