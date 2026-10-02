import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kilonova/theme/tokens.dart';
import 'package:kilonova/widgets/amount.dart';

import 'harness.dart';

BigInt xmr(String s) => parseXmr(s)!;

/// The spans of the single AmountText on screen, as (text, style) pairs.
List<(String, TextStyle)> spans(WidgetTester tester) {
  final text = tester.widget<Text>(
    find.descendant(of: find.byType(AmountText), matching: find.byType(Text)),
  );
  return [
    for (final s in (text.textSpan! as TextSpan).children!.cast<TextSpan>())
      (s.text!, s.style!),
  ];
}

void main() {
  group('formatXmrGrouped', () {
    test('groups the whole part in thousands', () {
      expect(formatXmrGrouped(xmr('2607.498016962174')), '2,607.498016962174');
      expect(formatXmrGrouped(xmr('1234567.5')), '1,234,567.5');
      expect(formatXmrGrouped(xmr('999.25')), '999.25');
    });
    test('shows whole numbers with one decimal', () {
      expect(formatXmrGrouped(xmr('1000')), '1,000.0');
      expect(formatXmrGrouped(BigInt.zero), '0.0');
    });
    test('pads to 12 decimals when full', () {
      expect(formatXmrGrouped(xmr('1000.5'), full: true), '1,000.500000000000');
    });
    test('leaves formatXmr ungrouped', () {
      expect(formatXmr(xmr('2607.4980')), '2607.498');
    });
  });

  group('AmountText', () {
    testWidgets('dims the decimals after the fourth, smaller', (tester) async {
      await pumpThemed(tester, AmountText(xmr('2607.498016962174'), size: 20));
      final s = spans(tester);
      expect(s.map((e) => e.$1), ['2,607.4980', '16962174', ' XMR']);
      expect(s[0].$2.color, KnColors.light.text);
      expect(s[0].$2.fontSize, 20);
      expect(s[0].$2.fontFamily, KnFonts.mono);
      expect(s[1].$2.color, KnColors.light.textSecondary);
      expect(s[1].$2.fontSize, 16);
      expect(s[2].$2.color, KnColors.light.textSecondary);
      expect(find.text('2,607.498016962174 XMR'), findsOneWidget);
    });

    testWidgets('drops trailing zeros and has no tail for short amounts', (
      tester,
    ) async {
      await pumpThemed(tester, AmountText(xmr('1.5')));
      expect(spans(tester).map((e) => e.$1), ['1.5', ' XMR']);
    });

    testWidgets('shows whole numbers with one decimal', (tester) async {
      await pumpThemed(tester, AmountText(xmr('3000')));
      expect(find.text('3,000.0 XMR'), findsOneWidget);
    });

    testWidgets('puts the prefix before the number, keeps the unit', (
      tester,
    ) async {
      await pumpThemed(
        tester,
        AmountText(
          xmr('34.79751'),
          prefix: '+',
          color: KnColors.light.received,
        ),
      );
      final s = spans(tester);
      expect(s.map((e) => e.$1), ['+34.7975', '1', ' XMR']);
      expect(s[0].$2.color, KnColors.light.received);
      expect(s[2].$2.color, KnColors.light.textSecondary);
    });

    testWidgets('an empty unit hides it', (tester) async {
      await pumpThemed(tester, AmountText(xmr('2'), unit: ''));
      expect(find.text('2.0'), findsOneWidget);
    });

    testWidgets('tapping toggles full precision at one size', (tester) async {
      await pumpThemed(tester, AmountText(xmr('2607.498016962174')));
      await tester.tap(find.byType(AmountText));
      await tester.pump();
      final s = spans(tester);
      expect(find.text('2,607.498016962174 XMR'), findsOneWidget);
      expect(s[1].$2.fontSize, s[0].$2.fontSize);

      await tester.tap(find.byType(AmountText));
      await tester.pump();
      expect(
        spans(tester)[1].$2.fontSize,
        lessThan(spans(tester)[0].$2.fontSize!),
      );
    });

    testWidgets('takes its size from a text theme role', (tester) async {
      await pumpThemed(
        tester,
        Builder(
          builder: (context) => AmountText(
            xmr('1.25'),
            style: Theme.of(context).textTheme.displayLarge,
          ),
        ),
      );
      final s = spans(tester);
      expect(s[0].$2.fontSize, 40);
      expect(s[0].$2.fontWeight, FontWeight.w500);
      expect(s[0].$2.fontFamily, KnFonts.mono);
    });
  });
}
