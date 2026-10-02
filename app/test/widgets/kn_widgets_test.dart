import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kilonova/theme/tokens.dart';
import 'package:kilonova/widgets/kn_button.dart';
import 'package:kilonova/widgets/kn_card.dart';
import 'package:kilonova/widgets/kn_field.dart';
import 'package:kilonova/widgets/kn_icons.dart';
import 'package:kilonova/widgets/kn_segments.dart';
import 'package:kilonova/widgets/kn_sheet.dart';

import 'harness.dart';

void main() {
  group('KnField', () {
    testWidgets('shows the label above the field and the helper below', (
      tester,
    ) async {
      await pumpThemed(
        tester,
        const KnField(
          label: 'Amount',
          helper: 'Up to 12 decimals',
          suffix: 'XMR',
        ),
      );
      final label = tester.getRect(find.text('Amount'));
      final field = tester.getRect(find.byType(TextField));
      final helper = tester.getRect(find.text('Up to 12 decimals'));
      expect(label.bottom, lessThanOrEqualTo(field.top));
      expect(helper.top, greaterThanOrEqualTo(field.bottom));
      expect(find.text('XMR'), findsOneWidget);
      final decoration = tester.widget<TextField>(find.byType(TextField));
      expect(decoration.decoration!.labelText, isNull);
    });

    testWidgets('an error replaces the helper, in the error color', (
      tester,
    ) async {
      await pumpThemed(
        tester,
        const KnField(label: 'To', helper: 'Help', error: 'Not an address'),
      );
      expect(find.text('Help'), findsNothing);
      final error = tester.widget<Text>(find.text('Not an address'));
      expect(error.style!.color, KnColors.light.error);
    });

    testWidgets('puts trailing buttons below the field, right-aligned', (
      tester,
    ) async {
      await pumpThemed(
        tester,
        KnField(
          label: 'To',
          mono: true,
          multiline: true,
          trailing: [
            KnIconButton(
              icon: const KnIcon(KnIcons.scan),
              tooltip: 'Scan',
              onPressed: () {},
            ),
            KnIconButton(
              icon: const KnIcon(KnIcons.paste),
              tooltip: 'Paste',
              onPressed: () {},
            ),
          ],
        ),
      );
      final field = tester.getRect(find.byType(TextField));
      final paste = tester.getRect(find.byTooltip('Paste'));
      final scan = tester.getRect(find.byTooltip('Scan'));
      expect(paste.top, greaterThanOrEqualTo(field.bottom));
      expect(paste.right, moreOrLessEquals(field.right));
      expect(scan.right, lessThanOrEqualTo(paste.left));
      expect(paste.size, const Size.square(36));
    });

    testWidgets('validates inside a Form', (tester) async {
      final key = GlobalKey<FormState>();
      final controller = TextEditingController(text: 'abc');
      addTearDown(controller.dispose);
      await pumpThemed(
        tester,
        Form(
          key: key,
          child: KnField(
            controller: controller,
            label: 'Name',
            validator: (v) => v!.length < 5 ? 'Too short' : null,
          ),
        ),
      );
      expect(key.currentState!.validate(), isFalse);
      await tester.pump();
      expect(find.text('Too short'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'abcdef');
      expect(key.currentState!.validate(), isTrue);
      await tester.pump();
      expect(find.text('Too short'), findsNothing);
    });
  });

  group('KnSegments', () {
    testWidgets('fills the selected segment and reports taps', (tester) async {
      var selected = 'normal';
      await pumpThemed(
        tester,
        StatefulBuilder(
          builder: (context, setState) => KnSegments<String>(
            segments: const [
              KnSegment('low', 'Low'),
              KnSegment('normal', 'Normal'),
              KnSegment('high', 'High'),
            ],
            selected: selected,
            onChanged: (v) => setState(() => selected = v),
          ),
        ),
      );
      Color fill(String label) => tester
          .widget<Material>(
            find
                .ancestor(of: find.text(label), matching: find.byType(Material))
                .first,
          )
          .color!;

      expect(tester.getSize(find.byType(KnSegments<String>)).height, 32);
      expect(fill('Normal'), KnColors.light.accent);
      expect(fill('High'), KnColors.light.surface);
      expect(
        tester.widget<Text>(find.text('Normal')).style!.color,
        KnColors.light.onAccent,
      );

      await tester.tap(find.text('High'));
      await tester.pump();
      expect(selected, 'high');
      expect(fill('High'), KnColors.light.accent);
      expect(fill('Normal'), KnColors.light.surface);
    });
  });

  group('KnRow', () {
    Finder bar() => find.descendant(
      of: find.byType(KnRow),
      matching: find.byWidgetPredicate(
        (w) => w is ColoredBox && w.color == KnColors.dark.accent,
      ),
    );

    testWidgets('selected rows get the raised fill and the gold bar', (
      tester,
    ) async {
      await pumpThemed(
        tester,
        const KnCard(
          padding: EdgeInsets.zero,
          child: KnRow(
            title: Text('Everyday'),
            subtitle: Text('2,607.4980 XMR'),
            selected: true,
          ),
        ),
        brightness: Brightness.dark,
      );
      final material = tester.widget<Material>(
        find.descendant(
          of: find.byType(KnRow),
          matching: find.byType(Material),
        ),
      );
      expect(material.color, KnColors.dark.surfaceRaised);
      expect(bar(), findsOneWidget);
      expect(tester.getSize(bar()).width, 3);
      expect(
        tester.getSize(find.byType(KnRow)).height,
        greaterThanOrEqualTo(52),
      );
    });

    testWidgets('unselected rows have neither, and report taps', (
      tester,
    ) async {
      var taps = 0;
      await pumpThemed(
        tester,
        KnRow(title: const Text('Savings'), onTap: () => taps++),
        brightness: Brightness.dark,
      );
      expect(bar(), findsNothing);
      await tester.tap(find.text('Savings'));
      expect(taps, 1);
    });
  });

  group('KnIcons', () {
    for (final size in [16.0, 20.0, 24.0]) {
      testWidgets('every glyph paints at $size', (tester) async {
        await pumpThemed(
          tester,
          Wrap(
            children: [
              for (final icon in KnIcons.values) KnIcon(icon, size: size),
            ],
          ),
        );
        expect(tester.takeException(), isNull);
        for (final icon in KnIcons.values) {
          expect(
            tester.getSize(
              find.byWidgetPredicate((w) => w is KnIcon && w.icon == icon),
            ),
            Size.square(size),
          );
        }
      });
    }

    testWidgets('takes the ambient icon color by default', (tester) async {
      await pumpThemed(
        tester,
        const IconTheme(
          data: IconThemeData(color: KnQr.ink),
          child: KnIcon(KnIcons.send),
        ),
      );
      final paint = tester.widget<CustomPaint>(
        find.descendant(
          of: find.byType(KnIcon),
          matching: find.byType(CustomPaint),
        ),
      );
      expect((paint.painter! as KnIconPainter).color, KnQr.ink);
    });
  });

  group('KnButton', () {
    testWidgets('variants build on the themed Material buttons', (
      tester,
    ) async {
      await pumpThemed(
        tester,
        Column(
          children: [
            KnButton.primary(
              'Send',
              icon: const KnIcon(KnIcons.send),
              onPressed: () {},
            ),
            KnButton.secondary('Receive', onPressed: () {}),
            KnButton.text('Cancel', onPressed: () {}),
            KnButton.primary('Review', expand: true, onPressed: null),
          ],
        ),
      );
      expect(find.widgetWithText(FilledButton, 'Send'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Receive'), findsOneWidget);
      expect(find.widgetWithText(TextButton, 'Cancel'), findsOneWidget);
      expect(
        tester.getSize(find.widgetWithText(FilledButton, 'Send')).height,
        44,
      );
      expect(
        tester.getSize(find.widgetWithText(FilledButton, 'Review')).width,
        tester.getSize(find.byType(Column)).width,
      );
    });
  });

  group('Eyebrow and KeyValue', () {
    testWidgets('eyebrows are upper case and spaced', (tester) async {
      await pumpThemed(tester, const Eyebrow('Balance'));
      final text = tester.widget<Text>(find.text('BALANCE'));
      expect(text.style!.letterSpacing, 0.6);
    });

    testWidgets('key-value rows sit on one 36px line', (tester) async {
      await pumpThemed(
        tester,
        Column(
          children: withDividers(const [
            KeyValue(label: 'Network fee', value: Text('0.0001')),
            KeyValue(
              label: 'Leaves this wallet',
              value: Text('2.5'),
              strong: true,
            ),
          ]),
        ),
      );
      expect(find.byType(KnDivider), findsOneWidget);
      expect(tester.getSize(find.byType(KeyValue).first).height, 36);
    });
  });

  group('showKnDialog', () {
    Future<void> open(WidgetTester tester) async {
      await pumpThemed(
        tester,
        Builder(
          builder: (context) => KnButton.text(
            'Open',
            onPressed: () => showKnDialog<void>(
              context,
              const Text('Body'),
              title: 'Title',
              actions: [KnButton.primary('Done', onPressed: () {})],
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
    }

    testWidgets('is a dialog at desktop width', (tester) async {
      tester.view.physicalSize = const Size(1280, 860);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await open(tester);
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.text('Title'), findsOneWidget);
      expect(find.text('Done'), findsOneWidget);
    });

    testWidgets('is a bottom sheet at phone width', (tester) async {
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await open(tester);
      expect(find.byType(Dialog), findsNothing);
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text('Body'), findsOneWidget);
    });
  });
}
