import 'package:flutter/material.dart';

import 'features/wallets/wallet_registry.dart';
import 'features/wallets/wallets_screen.dart';
import 'l10n/generated/app_localizations.dart';
import 'src/rust/api/network.dart';
import 'theme/theme.dart';

class KilonovaApp extends StatefulWidget {
  const KilonovaApp({super.key, required this.registry});

  final WalletRegistry registry;

  @override
  State<KilonovaApp> createState() => _KilonovaAppState();
}

class _KilonovaAppState extends State<KilonovaApp> {
  // Not persisted: the app opens on mainnet, or on the network of the only
  // wallets that exist.
  late final _network = ValueNotifier(_initialNetwork());
  // Unlocked wallets are locked as soon as the app leaves the foreground on
  // mobile, so a phone handed to someone else does not expose them.
  late final _lifecycle = AppLifecycleListener(
    onPause: widget.registry.lockAll,
  );

  Network _initialNetwork() {
    for (final n in allNetworks()) {
      if (widget.registry.on(n).isNotEmpty) return n;
    }
    return Network.mainnet;
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _network.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: WalletsScreen(network: _network, registry: widget.registry),
    );
  }
}
