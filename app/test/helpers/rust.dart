import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kilonova/app.dart';
import 'package:kilonova/features/settings/price_feed.dart';
import 'package:kilonova/features/wallets/wallet_registry.dart';
import 'package:kilonova/platform/biometric_unlock.dart';
import 'package:kilonova/platform/notifications.dart';
import 'package:kilonova/src/rust/api/network.dart';
import 'package:kilonova/src/rust/api/nodes.dart';
import 'package:kilonova/src/rust/api/wallets.dart';
import 'package:kilonova/src/rust/frb_generated.dart';

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
  PriceFeed? price,
}) async {
  // Prices never come from the real service in tests.
  final registry = WalletRegistry(
    biometric: biometric,
    price: price ?? PriceFeed(fetch: () async => null),
  );
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
