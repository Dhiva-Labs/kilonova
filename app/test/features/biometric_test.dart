import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kilonova/platform/biometric_unlock.dart';
import 'package:kilonova/src/rust/api/network.dart';
import 'package:kilonova/src/rust/api/wallets.dart';

import '../helpers/fake_biometric.dart';
import '../helpers/rust.dart';

const password = 'biometric password';

Future<String> makeWallet(WidgetTester tester, String name) async {
  late String id;
  await tester.runAsync(() async {
    final seed = await generateSeed(format: SeedFormat.polyseed);
    final wallet = await createWalletFromSeed(
      name: name,
      network: Network.testnet,
      mode: SyncMode.full,
      words: seed.words.join(' '),
      password: password,
    );
    id = wallet.summary().id;
    wallet.lock();
  });
  return id;
}

Future<void> openWallet(WidgetTester tester, String name) async {
  await tester.tap(find.text('Testnet'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(name));
  await tester.pumpAndSettle();
}

Future<void> unlockWithPassword(WidgetTester tester) async {
  await tester.enterText(find.byType(TextField), password);
  await tester.tap(find.widgetWithText(FilledButton, 'Unlock'));
  await pumpUntilFound(tester, find.text('Main address'));
}

Future<void> openMenu(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Wallet options'));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(initRustForTests);

  testWidgets('turn on, unlock with it, turn off', (tester) async {
    useDesktopWindow(tester);
    final fake = FakeBiometric();
    final id = await makeWallet(tester, 'Phone');
    await tester.pumpWidget(await testApp(tester, biometric: fake));
    await openWallet(tester, 'Phone');

    expect(find.text('Unlock with fingerprint or face'), findsNothing);
    await unlockWithPassword(tester);

    // Turning it on asks for the password and checks it.
    await openMenu(tester);
    await tester.tap(find.text('Turn on biometric unlock'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'not it');
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    await pumpUntilFound(
      tester,
      find.text('That password does not open this wallet.'),
    );
    await tester.enterText(find.byType(TextField).last, password);
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    await pumpUntilFound(tester, find.text('Biometric unlock is on'));
    expect(fake.stored[id], password);

    // Lock, then unlock with the biometric prompt.
    await openMenu(tester);
    await tester.tap(find.text('Lock'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unlock with fingerprint or face'));
    await pumpUntilFound(tester, find.text('Main address'));

    await openMenu(tester);
    await tester.tap(find.text('Turn off biometric unlock'));
    await pumpUntilFound(tester, find.text('Biometric unlock is off'));
    expect(fake.stored, isEmpty);
  });

  testWidgets('new enrollment falls back to the password', (tester) async {
    useDesktopWindow(tester);
    final fake = FakeBiometric();
    final id = await makeWallet(tester, 'Enrolled');
    fake.stored[id] = password;
    fake.nextFailure = BiometricFailure.invalidated;
    await tester.pumpWidget(await testApp(tester, biometric: fake));
    await openWallet(tester, 'Enrolled');

    await tester.tap(find.text('Unlock with fingerprint or face'));
    await pumpUntilFound(
      tester,
      find.textContaining('biometric unlock was turned off'),
    );
    expect(find.text('Unlock with fingerprint or face'), findsNothing);
    expect(fake.stored, isEmpty);
  });

  testWidgets('cancelling the prompt changes nothing', (tester) async {
    useDesktopWindow(tester);
    final fake = FakeBiometric();
    final id = await makeWallet(tester, 'Cancel');
    fake.stored[id] = password;
    fake.nextFailure = BiometricFailure.cancelled;
    await tester.pumpWidget(await testApp(tester, biometric: fake));
    await openWallet(tester, 'Cancel');

    await tester.tap(find.text('Unlock with fingerprint or face'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilledButton, 'Unlock'), findsOneWidget);
    expect(find.textContaining('did not work'), findsNothing);
    expect(fake.stored[id], password);
  });

  testWidgets('changing the password turns biometric unlock off', (
    tester,
  ) async {
    useDesktopWindow(tester);
    final fake = FakeBiometric();
    final id = await makeWallet(tester, 'Rotate');
    fake.stored[id] = password;
    await tester.pumpWidget(await testApp(tester, biometric: fake));
    await openWallet(tester, 'Rotate');
    await unlockWithPassword(tester);

    await openMenu(tester);
    await tester.tap(find.text('Change password'));
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(fields.evaluate().length - 3), password);
    await tester.enterText(
      fields.at(fields.evaluate().length - 2),
      'new password 1',
    );
    await tester.enterText(
      fields.at(fields.evaluate().length - 1),
      'new password 1',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await pumpUntilFound(
      tester,
      find.textContaining('Biometric unlock was turned off'),
    );
    expect(fake.stored, isEmpty);
  });
}
