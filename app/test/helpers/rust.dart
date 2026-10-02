import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:kilonova/src/rust/frb_generated.dart';

/// Loads the debug build of the Rust core for host-side widget tests.
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
}
