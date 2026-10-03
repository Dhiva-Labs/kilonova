import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/kn_card.dart';
import '../wallets/wallet_registry.dart';
import 'about_screen.dart';
import 'background_screen.dart';
import 'lws_servers_screen.dart';
import 'nodes_screen.dart';
import 'pair_server_screen.dart';
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

    Widget row({
      required IconData icon,
      required String title,
      required String subtitle,
      required VoidCallback onTap,
    }) => KnRow(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );

    return Scaffold(
      appBar: AppBar(title: Text(l.settingsTitle)),
      body: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: EdgeInsets.all(
              context.isPhoneWidth ? KnSpace.md : KnSpace.xl,
            ),
            children: [
              Eyebrow(l.settingsNetworkSection),
              const SizedBox(height: KnSpace.sm),
              KnCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: withDividers([
                    row(
                      icon: Icons.dns_outlined,
                      title: l.nodesTitle,
                      subtitle: l.nodesSubtitle,
                      onTap: () => open(const NodesScreen()),
                    ),
                    row(
                      icon: Icons.cloud_outlined,
                      title: l.lwsTitle,
                      subtitle: l.lwsSubtitle,
                      onTap: () => open(LwsServersScreen(registry: registry)),
                    ),
                    row(
                      icon: Icons.vpn_lock_outlined,
                      title: l.proxyTitle,
                      subtitle: l.proxySubtitle,
                      onTap: () => open(const ProxyScreen()),
                    ),
                    row(
                      icon: Icons.dns_outlined,
                      title: l.pairServerRow,
                      subtitle: l.pairServerSubtitle,
                      onTap: () => open(const PairServerScreen()),
                    ),
                  ]),
                ),
              ),
              const SizedBox(height: KnSpace.lg),
              Eyebrow(l.settingsOptionsSection),
              const SizedBox(height: KnSpace.sm),
              KnCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: withDividers([
                    row(
                      icon: Icons.currency_exchange_outlined,
                      title: l.pricesTitle,
                      subtitle: l.pricesSubtitle,
                      onTap: () => open(PricesScreen(feed: registry.price)),
                    ),
                    row(
                      icon: Icons.notifications_none_outlined,
                      title: l.backgroundTitle,
                      subtitle: l.backgroundSubtitle,
                      onTap: () => open(BackgroundScreen(registry: registry)),
                    ),
                  ]),
                ),
              ),
              const SizedBox(height: KnSpace.lg),
              Eyebrow(l.settingsAboutSection),
              const SizedBox(height: KnSpace.sm),
              KnCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: withDividers([
                    row(
                      icon: Icons.shield_outlined,
                      title: l.privacyTitle,
                      subtitle: l.privacySubtitle,
                      onTap: () => open(const PrivacyScreen()),
                    ),
                    row(
                      icon: Icons.info_outline,
                      title: l.aboutTitle,
                      subtitle: l.aboutSubtitle,
                      onTap: () => open(const AboutScreen()),
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
