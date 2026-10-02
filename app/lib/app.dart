import 'package:flutter/material.dart';

import 'features/wallets/wallets_screen.dart';
import 'l10n/generated/app_localizations.dart';
import 'src/rust/api/network.dart';
import 'theme/theme.dart';

class KilonovaApp extends StatefulWidget {
  const KilonovaApp({super.key});

  @override
  State<KilonovaApp> createState() => _KilonovaAppState();
}

class _KilonovaAppState extends State<KilonovaApp> {
  // Not persisted yet: the wallet registry that remembers it arrives with
  // multi-wallet support in M1.
  final _network = ValueNotifier(Network.mainnet);

  @override
  void dispose() {
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
      home: WalletsScreen(network: _network),
    );
  }
}
