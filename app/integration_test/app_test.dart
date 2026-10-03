import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_zxing/flutter_zxing.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kilonova/app.dart';
import 'package:kilonova/features/send/monero_uri.dart';
import 'package:kilonova/features/wallets/wallet_registry.dart';
import 'package:kilonova/platform/notifications.dart';
import 'package:kilonova/platform/biometric_unlock.dart';
import 'package:kilonova/src/rust/api/network.dart';
import 'package:kilonova/src/rust/api/wallets.dart';
import 'package:kilonova/src/rust/frb_generated.dart';
import 'package:kilonova/theme/tokens.dart';

/// Runs the real app with the Rust core built by the platform toolchain,
/// proving the flutter_rust_bridge wiring end to end.
///
/// Everything lives in one file because Flutter's desktop runner cannot
/// start the app a second time in one `flutter test integration_test` run.
///
/// The biometric test runs on Android only and exercises the real Keystore
/// and BiometricPrompt. It needs an enrolled fingerprint and someone (or
/// `adb emu finger touch 1` in a loop) to touch the sensor; see
/// CONTRIBUTING.md.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  late WalletRegistry registry;

  setUpAll(() async {
    await RustLib.init();
    final dir = Directory.systemTemp.createTempSync('kilonova-it-');
    await initWalletStore(dir: dir.path);
    registry = WalletRegistry();
    await registry.reload();
  });

  testWidgets('app boots and reads the network list from Rust', (tester) async {
    await tester.pumpWidget(KilonovaApp(registry: registry));

    expect(find.widgetWithText(FilledButton, 'Create wallet'), findsOneWidget);

    // The network menu lists every network the core knows.
    await tester.tap(find.byType(PopupMenuButton<Network>));
    await tester.pumpAndSettle();
    expect(find.text('Mainnet'), findsWidgets);
    expect(find.text('Stagenet'), findsOneWidget);
    expect(find.text('Testnet'), findsOneWidget);
    await tester.tapAt(Offset.zero);
    await tester.pumpAndSettle();
  });

  testWidgets('QR codes the app shows can be read back by its scanner', (
    tester,
  ) async {
    const address =
        '44AFFq5kSiGBoZ4NMDwYtN18obc8AemS33DBLWs3H7otXft3XjrpDtQGv7SqSsaBYBb98uNbr2VBBEt7f2wfn3RVGQBEP3A';
    final uri = paymentRequestUri(address, amount: BigInt.from(1500000000));
    // Dark modules on white with a quiet zone, as the receive dialog shows.
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)
      ..drawRect(
        const Rect.fromLTWH(0, 0, 700, 700),
        Paint()..color = KnQr.paper,
      );
    canvas.translate(50, 50);
    QrPainter(
      data: uri,
      version: QrVersions.auto,
      gapless: true,
      eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: KnQr.ink),
      dataModuleStyle: const QrDataModuleStyle(
        dataModuleShape: QrDataModuleShape.square,
        color: KnQr.ink,
      ),
    ).paint(canvas, const Size(600, 600));
    final image = await recorder.endRecording().toImage(700, 700);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('${Directory.systemTemp.createTempSync().path}/qr.png')
      ..writeAsBytesSync(png!.buffer.asUint8List());
    final code = await zx.readBarcodeImagePath(
      XFile(file.path),
      DecodeParams(format: Format.qrCode, tryHarder: true, maxSize: 1600),
    );
    expect(code.isValid, isTrue, reason: code.error);
    expect(code.text, uri);
    expect(parsePaymentRequest(code.text!)!.payments.single.address, address);
  });

  testWidgets(
    'Android: background sync service and payment notifications appear',
    (tester) async {
      const notifier = Notifier();
      await notifier.requestPermission();
      await notifier.startKeepAlive(title: 'Kilonova is syncing', text: 'test');
      await notifier.payment(
        id: 7,
        title: 'Payment received in Test',
        body: '+1.5 XMR',
        publicTitle: 'Kilonova: payment received',
      );
      // Long enough for `adb shell dumpsys notification` to see both; see
      // CONTRIBUTING.md.
      await Future<void>.delayed(const Duration(seconds: 15));
      await notifier.stopKeepAlive();
    },
    skip: !Platform.isAndroid,
  );

  testWidgets('privacy policy renders from the bundled asset', (tester) async {
    await tester.pumpWidget(KilonovaApp(registry: registry));

    // A text button on wide windows, an icon on phones.
    final settings = find.text('Settings');
    await tester.tap(
      settings.evaluate().isNotEmpty ? settings : find.byTooltip('Settings'),
    );
    await tester.pumpAndSettle();
    // The settings list builds rows as they scroll in.
    await tester.scrollUntilVisible(
      find.text('Privacy policy'),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Privacy policy'));
    await tester.pumpAndSettle();

    expect(find.text('Kilonova privacy policy'), findsOneWidget);
  });

  Future<void> waitFor(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 300; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (finder.evaluate().isNotEmpty) return;
    }
    throw TestFailure('Timed out waiting for $finder');
  }

  testWidgets('biometric unlock round trip through the Keystore', (
    tester,
  ) async {
    expect(
      await const BiometricUnlock().isAvailable(),
      isTrue,
      reason: 'enroll a fingerprint on the device first',
    );
    final seed = await generateSeed(format: SeedFormat.polyseed);
    (await createWalletFromSeed(
      name: 'Fingerprint',
      network: Network.mainnet,
      mode: SyncMode.full,
      words: seed.words.join(' '),
      password: 'emulator password',
      createdHere: true,
    )).lock();
    await registry.reload();

    await tester.pumpWidget(KilonovaApp(registry: registry));
    await tester.tap(find.text('Fingerprint'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'emulator password');
    await tester.tap(find.widgetWithText(FilledButton, 'Unlock'));
    await waitFor(tester, find.text('Balance'));
    // The menu asks Android whether biometrics are available; let that
    // answer arrive before opening it.
    await tester.pump(const Duration(seconds: 1));

    await tester.tap(find.byTooltip('Wallet options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Turn on biometric unlock'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'emulator password');
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    // The system prompt appears here; the fingerprint completes it.
    await waitFor(tester, find.text('Biometric unlock is on'));

    await tester.tap(find.byTooltip('Wallet options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lock'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Unlock with fingerprint or face'));
    await waitFor(tester, find.text('Balance'));
  }, skip: !Platform.isAndroid);
}
