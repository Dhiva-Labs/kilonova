import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../platform/desktop_shell.dart';
import '../../src/rust/api/preferences.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/error_line.dart';
import '../../widgets/kn_card.dart';
import '../wallets/wallet_registry.dart';
import 'background_consent_screen.dart';
import 'push_screen.dart';

/// Payment notifications, and background work: checks for payments with
/// the app closed (Android) or syncing with the window closed (Linux,
/// Windows). Everything starts off; background work is turned on only
/// through the consent screen.
class BackgroundScreen extends StatefulWidget {
  const BackgroundScreen({super.key, required this.registry, this.desktop});

  final WalletRegistry registry;

  /// Whether to offer keeping wallets syncing with the window closed;
  /// defaults to whether this is Linux or Windows.
  final bool? desktop;

  @override
  State<BackgroundScreen> createState() => _BackgroundScreenState();
}

class _BackgroundScreenState extends State<BackgroundScreen> {
  late Preferences _prefs = widget.registry.preferences;
  bool _denied = false;
  int _checked = 0;

  @override
  void initState() {
    super.initState();
    _loadChecked();
  }

  Future<void> _loadChecked() async {
    final ids = await widget.registry.checkedWallets();
    if (mounted) {
      setState(() {
        _checked = ids.length;
        _prefs = widget.registry.preferences;
      });
    }
  }

  Future<void> _notify(bool on) async {
    var allowed = true;
    if (on) allowed = await widget.registry.notifier.requestPermission();
    final next = Preferences(
      notifyIncoming: on,
      backgroundSync: _prefs.backgroundSync,
      confirmLwsPayments: _prefs.confirmLwsPayments,
      broadcastElsewhere: _prefs.broadcastElsewhere,
    );
    await setPreferences(preferences: next);
    widget.registry.preferences = next;
    if (mounted) {
      setState(() {
        _prefs = next;
        _denied = on && !allowed;
      });
    }
  }

  /// Turning background work on goes through the consent screen; turning
  /// it off deletes what was kept.
  Future<void> _background(bool on, {required bool desktop}) async {
    if (on) {
      final agreed = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => BackgroundConsentScreen(
            registry: widget.registry,
            desktop: desktop,
          ),
        ),
      );
      if (agreed == true && desktop) {
        await widget.registry.setBackgroundChecks(on: true);
      }
    } else {
      await widget.registry.setBackgroundChecks(on: false);
    }
    await _loadChecked();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final checks = widget.registry.background.supported;
    final desktop = widget.desktop ?? DesktopShell.supported;
    final phone = context.isPhoneWidth;
    final push = widget.registry.push.supported;

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
                        onChanged: _notify,
                      ),
                    ),
                    if (checks) ...[
                      KnRow(
                        title: Text(l.checksLabel),
                        subtitle: Text(
                          _prefs.backgroundSync
                              ? l.checksOnHelp(_checked)
                              : l.checksOffHelp,
                        ),
                        trailing: Switch(
                          value: _prefs.backgroundSync,
                          onChanged: (on) => _background(on, desktop: false),
                        ),
                      ),
                      if (_prefs.backgroundSync)
                        KnRow(
                          title: Text(l.checksWalletsRow),
                          subtitle: Text(l.checksWalletsHelp),
                          onTap: () async {
                            await Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => BackgroundWalletsScreen(
                                  registry: widget.registry,
                                ),
                              ),
                            );
                            await _loadChecked();
                          },
                        ),
                    ],
                    if (!checks && desktop)
                      KnRow(
                        title: Text(l.keepSyncingWindowLabel),
                        subtitle: Text(
                          widget.registry.hasTray
                              ? l.keepSyncingWindowHelp
                              : '${l.keepSyncingWindowHelp} ${l.keepSyncingNoTray}',
                        ),
                        trailing: Switch(
                          value: _prefs.backgroundSync,
                          onChanged: (on) => _background(on, desktop: true),
                        ),
                      ),
                    if (push)
                      KnRow(
                        title: Text(l.pushRow),
                        subtitle: Text(l.pushSubtitle),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                PushScreen(registry: widget.registry),
                          ),
                        ),
                      ),
                  ]),
                ),
              ),
              if (!checks) ...[
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
