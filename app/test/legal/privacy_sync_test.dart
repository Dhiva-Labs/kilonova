import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kilonova/features/settings/privacy_screen.dart';

void main() {
  test('bundled privacy policy matches PRIVACY.md at the repo root', () {
    final bundled = File(privacyPolicyAsset).readAsStringSync();
    final canonical = File('../PRIVACY.md').readAsStringSync();
    expect(
      bundled,
      canonical,
      reason: 'Copy PRIVACY.md to app/$privacyPolicyAsset after editing it.',
    );
  });
}
