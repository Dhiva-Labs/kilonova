import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kilonova/app.dart';
import 'package:kilonova/features/wallets/wallet_registry.dart';
import 'package:kilonova/platform/biometric_unlock.dart';
import 'package:kilonova/src/rust/api/network.dart';
import 'package:kilonova/src/rust/api/wallets.dart';
import 'package:kilonova/src/rust/frb_generated.dart';

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

    expect(find.text('Mainnet'), findsOneWidget);
    expect(find.text('Stagenet'), findsOneWidget);
    expect(find.text('Testnet'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Create wallet'), findsOneWidget);
  });

  testWidgets('privacy policy renders from the bundled asset', (tester) async {
    await tester.pumpWidget(KilonovaApp(registry: registry));

    await tester.tap(find.byTooltip('Settings'));
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
    )).lock();
    await registry.reload();

    await tester.pumpWidget(KilonovaApp(registry: registry));
    await tester.tap(find.text('Fingerprint'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'emulator password');
    await tester.tap(find.widgetWithText(FilledButton, 'Unlock'));
    await waitFor(tester, find.text('Main address'));
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
    await waitFor(tester, find.text('Main address'));
  }, skip: !Platform.isAndroid);
}
