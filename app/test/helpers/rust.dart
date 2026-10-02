import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kilonova/app.dart';
import 'package:kilonova/features/wallets/wallet_registry.dart';
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
}

/// Builds the app around a freshly loaded wallet registry.
Future<Widget> testApp(WidgetTester tester) async {
  final registry = WalletRegistry();
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
    await tester.pump();
    if (finder.evaluate().isNotEmpty) return;
  }
  throw TestFailure('Timed out waiting for $finder');
}

/// Sets a desktop-sized window so the two-pane layout is used.
void useDesktopWindow(WidgetTester tester) {
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}
