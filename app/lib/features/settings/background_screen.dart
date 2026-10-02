import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../src/rust/api/preferences.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/error_line.dart';
import '../../widgets/kn_card.dart';
import '../wallets/wallet_registry.dart';

/// Payment notifications and background sync. Both start off.
class BackgroundScreen extends StatefulWidget {
  const BackgroundScreen({super.key, required this.registry});

  final WalletRegistry registry;

  @override
  State<BackgroundScreen> createState() => _BackgroundScreenState();
}

class _BackgroundScreenState extends State<BackgroundScreen> {
  late Preferences _prefs = widget.registry.preferences;
  bool _denied = false;

  Future<void> _save(Preferences next) async {
    var allowed = true;
    if (next.notifyIncoming && !_prefs.notifyIncoming) {
      allowed = await widget.registry.notifier.requestPermission();
    }
    await setPreferences(preferences: next);
    widget.registry.preferences = next;
    if (mounted) {
      setState(() {
        _prefs = next;
        _denied = next.notifyIncoming && !allowed;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final background = widget.registry.notifier.supportsBackgroundSync;
    final phone = context.isPhoneWidth;

    return Scaffold(
      appBar: AppBar(title: Text(l.backgroundTitle)),
      body: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: EdgeInsets.all(phone ? KnSpace.md : KnSpace.xl),
            children: [
              KnCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: withDividers([
                    KnRow(
                      title: Text(l.notifyIncomingLabel),
                      subtitle: Text(l.notifyIncomingHelp),
                      trailing: Switch(
                        value: _prefs.notifyIncoming,
                        onChanged: (on) => _save(
                          Preferences(
                            notifyIncoming: on,
                            backgroundSync: _prefs.backgroundSync,
                          ),
                        ),
                      ),
                    ),
                    if (background)
                      KnRow(
                        title: Text(l.backgroundSyncLabel),
                        subtitle: Text(l.backgroundSyncHelp),
                        trailing: Switch(
                          value: _prefs.backgroundSync,
                          onChanged: (on) => _save(
                            Preferences(
                              notifyIncoming: _prefs.notifyIncoming,
                              backgroundSync: on,
                            ),
                          ),
                        ),
                      ),
                  ]),
                ),
              ),
              if (!background) ...[
                const SizedBox(height: KnSpace.md),
                Text(l.backgroundDesktopNote, style: text.bodyMedium),
              ],
              if (_denied) ...[
                const SizedBox(height: KnSpace.md),
                ErrorLine(l.notifyDenied),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
