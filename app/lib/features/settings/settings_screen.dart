import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import '../wallets/wallet_registry.dart';
import 'about_screen.dart';
import 'background_screen.dart';
import 'lws_servers_screen.dart';
import 'nodes_screen.dart';
import 'prices_screen.dart';
import 'privacy_screen.dart';
import 'proxy_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.registry});

  final WalletRegistry registry;

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
            leading: const Icon(Icons.cloud_outlined),
            title: Text(l.lwsTitle),
            subtitle: Text(l.lwsSubtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => open(const LwsServersScreen()),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.vpn_lock_outlined),
            title: Text(l.proxyTitle),
            subtitle: Text(l.proxySubtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => open(const ProxyScreen()),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.currency_exchange_outlined),
            title: Text(l.pricesTitle),
            subtitle: Text(l.pricesSubtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => open(PricesScreen(feed: registry.price)),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.notifications_none_outlined),
            title: Text(l.backgroundTitle),
            subtitle: Text(l.backgroundSubtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => open(BackgroundScreen(registry: registry)),
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
