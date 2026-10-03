import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'features/wallets/wallet_registry.dart';
import 'platform/desktop_shell.dart';
import 'platform/push.dart';
import 'src/rust/api/wallets.dart';
import 'src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  // Nothing in the app shows photos; the few images are the app icon, the
  // QR codes and the privacy policy's rendered markdown. Flutter's default
  // cache (1000 images, 100MB) is sized for a photo-heavy app, so it is
  // capped well below that here.
  PaintingBinding.instance.imageCache
    ..maximumSize = 100
    ..maximumSizeBytes = 20 << 20;
  LicenseRegistry.addLicense(() async* {
    final ofl = await rootBundle.loadString('assets/fonts/OFL.txt');
    yield LicenseEntryWithLineBreaks(const [
      'IBM Plex Sans',
      'IBM Plex Mono',
    ], ofl);
  });

  final support = await getApplicationSupportDirectory();
  await initWalletStore(dir: '${support.path}/wallets');
  final registry = WalletRegistry(push: PushChannel.forPlatform());
  await registry.reload();
  if (DesktopShell.supported) await DesktopShell(registry).start();
  // Pushes are only listened for once the owner turned them on for a
  // wallet; until then this does nothing on the network.
  unawaited(registry.startPush());

  runApp(KilonovaApp(registry: registry));
}
