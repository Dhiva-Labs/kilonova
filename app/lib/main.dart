import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'features/wallets/wallet_registry.dart';
import 'src/rust/api/wallets.dart';
import 'src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  LicenseRegistry.addLicense(() async* {
    final ofl = await rootBundle.loadString('assets/fonts/OFL.txt');
    yield LicenseEntryWithLineBreaks(const [
      'IBM Plex Sans',
      'IBM Plex Mono',
    ], ofl);
  });

  final support = await getApplicationSupportDirectory();
  await initWalletStore(dir: '${support.path}/wallets');
  final registry = WalletRegistry();
  await registry.reload();

  runApp(KilonovaApp(registry: registry));
}
