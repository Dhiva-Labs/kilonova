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

/// Exercises the real Android Keystore and BiometricPrompt. Needs a device
/// or emulator with an enrolled fingerprint, and someone (or a script running
/// `adb emu finger touch 1` in a loop) to touch the sensor when prompted.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

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
    await RustLib.init();
    expect(
      await const BiometricUnlock().isAvailable(),
      isTrue,
      reason: 'enroll a fingerprint on the device first',
    );
    final dir = Directory.systemTemp.createTempSync('kilonova-bio-');
    await initWalletStore(dir: dir.path);
    final seed = await generateSeed(format: SeedFormat.polyseed);
    (await createWalletFromSeed(
      name: 'Fingerprint',
      network: Network.mainnet,
      mode: SyncMode.full,
      words: seed.words.join(' '),
      password: 'emulator password',
    )).lock();
    final registry = WalletRegistry();
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
