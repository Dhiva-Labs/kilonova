import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../src/rust/api/preferences.dart';
import '../../theme/tokens.dart';
import '../../widgets/error_line.dart';
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
    return Scaffold(
      appBar: AppBar(title: Text(l.backgroundTitle)),
      body: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: KnSpace.md),
            children: [
              SwitchListTile(
                value: _prefs.notifyIncoming,
                title: Text(l.notifyIncomingLabel),
                subtitle: Text(l.notifyIncomingHelp),
                onChanged: (on) => _save(
                  Preferences(
                    notifyIncoming: on,
                    backgroundSync: _prefs.backgroundSync,
                  ),
                ),
              ),
              if (_denied)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: KnSpace.md),
                  child: ErrorLine(l.notifyDenied),
                ),
              const Divider(),
              if (background)
                SwitchListTile(
                  value: _prefs.backgroundSync,
                  title: Text(l.backgroundSyncLabel),
                  subtitle: Text(l.backgroundSyncHelp),
                  onChanged: (on) => _save(
                    Preferences(
                      notifyIncoming: _prefs.notifyIncoming,
                      backgroundSync: on,
                    ),
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.all(KnSpace.md),
                  child: Text(l.backgroundDesktopNote, style: text.bodyMedium),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
