import 'dart:math';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kilonova/theme/tokens.dart';

/// WCAG 2.x contrast ratio between two opaque colors.
double contrast(Color a, Color b) {
  double channel(double v) =>
      v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4).toDouble();
  double luminance(Color c) =>
      0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
  final la = luminance(a), lb = luminance(b);
  return (max(la, lb) + 0.05) / (min(la, lb) + 0.05);
}

void main() {
  for (final (name, c) in [
    ('light', KnColors.light),
    ('dark', KnColors.dark),
  ]) {
    group('$name tokens', () {
      for (final background in [c.bg, c.surface]) {
        test('body text meets AAA (7:1)', () {
          expect(contrast(c.text, background), greaterThanOrEqualTo(7));
        });
        test('meaningful colors meet AA (4.5:1)', () {
          for (final fg in [c.textSecondary, c.accent, c.received, c.error]) {
            expect(contrast(fg, background), greaterThanOrEqualTo(4.5));
          }
        });
      }
      test('text on accent fills meets AA, at rest and on hover', () {
        expect(contrast(c.onAccent, c.accent), greaterThanOrEqualTo(4.5));
        expect(contrast(c.onAccent, c.accentHover), greaterThanOrEqualTo(4.5));
      });
      test('test-network strip text meets AA', () {
        expect(
          contrast(c.onTestnetStrip, c.testnetStrip),
          greaterThanOrEqualTo(4.5),
        );
      });
      test('every token is opaque', () {
        for (final color in [
          c.bg,
          c.surface,
          c.border,
          c.text,
          c.textSecondary,
          c.accent,
          c.onAccent,
          c.accentHover,
          c.received,
          c.error,
          c.testnetStrip,
          c.onTestnetStrip,
        ]) {
          expect(color.a, 1.0);
        }
      });
    });
  }
}
