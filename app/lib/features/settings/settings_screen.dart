import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import 'about_screen.dart';
import 'nodes_screen.dart';
import 'privacy_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    void open(Widget screen) => Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => screen));

    return Scaffold(
      appBar: AppBar(title: Text(l.settingsTitle)),
      body: ListView(
        children: [
          const Divider(),
          ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: Text(l.nodesTitle),
            subtitle: Text(l.nodesSubtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => open(const NodesScreen()),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.shield_outlined),
            title: Text(l.privacyTitle),
            subtitle: Text(l.privacySubtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => open(const PrivacyScreen()),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: Text(l.aboutTitle),
            subtitle: Text(l.aboutSubtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => open(const AboutScreen()),
          ),
          const Divider(),
        ],
      ),
    );
  }
}
