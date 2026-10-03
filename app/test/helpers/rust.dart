import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kilonova/app.dart';
import 'package:kilonova/features/cold/cold_transport.dart';
import 'package:kilonova/features/settings/price_feed.dart';
import 'package:kilonova/features/wallets/wallet_registry.dart';
import 'package:kilonova/platform/biometric_unlock.dart';
import 'package:kilonova/platform/notifications.dart';
import 'package:kilonova/src/rust/api/cold.dart';
import 'package:kilonova/src/rust/api/network.dart';
import 'package:kilonova/src/rust/api/nodes.dart';
import 'package:kilonova/src/rust/api/wallets.dart';
import 'package:kilonova/src/rust/frb_generated.dart';
import 'package:kilonova/widgets/kn_field.dart';

/// Loads the debug build of the Rust core and points the wallet store at a
/// fresh temporary directory. Each test file runs in its own process, so
/// every file starts with no wallets.
///
/// Run `cargo build` in `core/` first; CI does this before `flutter test`.
Future<void> initRustForTests() async {
  if (RustLib.instance.initialized) return;
  final name = switch (Platform.operatingSystem) {
    'windows' => 'kn_ffi.dll',
    'macos' => 'libkn_ffi.dylib',
    _ => 'libkn_ffi.so',
  };
  final path = '../core/target/debug/$name';
  if (!File(path).existsSync()) {
    throw StateError('Missing $path. Run `cargo build` in core/ first.');
  }
  await RustLib.init(externalLibrary: ExternalLibrary.open(path));
  final dir = Directory.systemTemp.createTempSync('kilonova-test-');
  await initWalletStore(dir: dir.path);
  // Tests never touch the real network: sync goes to a closed local port
  // unless a test chooses another node.
  for (final network in Network.values) {
    await addNode(network: network, url: 'http://127.0.0.1:1');
  }
}

/// Builds the app around a freshly loaded wallet registry.
Future<Widget> testApp(
  WidgetTester tester, {
  BiometricUnlock biometric = const BiometricUnlock(),
  ColdTransport cold = const ColdTransport(),
  PriceFeed? price,
}) async {
  // Prices never come from the real service in tests.
  final registry = WalletRegistry(
    biometric: biometric,
    cold: cold,
    price: price ?? PriceFeed(fetch: () async => null),
  );
  await tester.runAsync(registry.reload);
  return KilonovaApp(registry: registry);
}

/// Builds the app around a given [registry], for tests that need to keep
/// a handle to it (for example to call `registry.cold` after pumping).
Future<Widget> testAppWithRegistry(
  WidgetTester tester,
  WalletRegistry registry,
) async {
  await tester.runAsync(registry.reload);
  return KilonovaApp(registry: registry);
}

/// Pumps, letting real async work (FFI calls, key derivation) run, until
/// [finder] matches or [timeout] passes.
Future<void> pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    // Advance the fake clock too, so animations (snackbars, routes) move.
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isNotEmpty) return;
  }
  final texts = find
      .byType(Text)
      .evaluate()
      .map(
        (e) =>
            (e.widget as Text).data ??
            (e.widget as Text).textSpan?.toPlainText(),
      )
      .whereType<String>()
      .take(30)
      .join(' | ');
  throw TestFailure('Timed out waiting for $finder. On screen: $texts');
}

/// Pumps like [pumpUntilFound] until [condition] holds.
Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  String? what,
  Duration timeout = const Duration(seconds: 20),
}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 50));
    if (condition()) return;
  }
  throw TestFailure('Timed out waiting for ${what ?? 'condition'}');
}

/// Sets a desktop-sized window so the two-pane layout is used.
void useDesktopWindow(WidgetTester tester) {
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// Records what the app would show, instead of showing it.
class FakeNotifier implements Notifier {
  FakeNotifier({this.supportsBackgroundSync = true});

  @override
  final bool supportsBackgroundSync;

  final payments = <(String, String)>[];
  bool keptAlive = false;

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<void> payment({
    required int id,
    required String title,
    required String body,
    required String publicTitle,
  }) async => payments.add((title, body));

  @override
  Future<void> startKeepAlive({
    required String title,
    required String text,
  }) async => keptAlive = true;

  @override
  Future<void> stopKeepAlive() async => keptAlive = false;
}

/// Records messages shown through `AnimatedQr`, and returns queued bytes
/// from `receive` instead of scanning a camera or opening a file.
class FakeColdTransport extends ColdTransport {
  FakeColdTransport();

  /// Bytes `receive` returns, in order; consumed one call at a time.
  final List<Uint8List> toReceive = [];

  /// Every message an `AnimatedQr` has shown, in order.
  final List<ColdMessage> shownMessages = [];

  /// Every message passed to `saveFile`.
  final List<ColdMessage> savedFiles = [];

  @override
  Future<Uint8List?> receive(
    BuildContext context, {
    required String title,
  }) async => toReceive.isEmpty ? null : toReceive.removeAt(0);

  @override
  Future<void> saveFile(BuildContext context, ColdMessage message) async {
    savedFiles.add(message);
  }

  @override
  void shown(ColdMessage message) {
    shownMessages.add(message);
  }
}

/// The [TextField] inside the [KnField] labelled [label] (label above the
/// field), or a plain [TextField]/[TextFormField] with that label (label
/// inside). Always resolves to the actual input, so both `enterText` and
/// `tester.widget<TextField>` work on the result.
Finder fieldWithLabel(String label) {
  final kn = find.widgetWithText(KnField, label);
  if (kn.evaluate().isNotEmpty) {
    return find.descendant(of: kn, matching: find.byType(TextField));
  }
  final field = find.widgetWithText(TextField, label);
  if (field.evaluate().isNotEmpty) return field;
  return find.widgetWithText(TextFormField, label);
}

/// Opens Settings from the wallet list, on either layout.
Future<void> openSettings(WidgetTester tester) async {
  final text = find.text('Settings');
  await tester.tap(
    text.evaluate().isNotEmpty ? text : find.byTooltip('Settings'),
  );
  await tester.pumpAndSettle();
}

/// Picks a network from the quiet network menu.
Future<void> chooseNetwork(WidgetTester tester, String label) async {
  await tester.tap(find.byType(PopupMenuButton<Network>));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

/// Opens the add-wallet menu, on either layout.
Future<void> openAddWallet(WidgetTester tester) async {
  final text = find.text('Add wallet');
  await tester.tap(
    text.evaluate().isNotEmpty ? text : find.byTooltip('Add a wallet'),
  );
  await tester.pumpAndSettle();
}
