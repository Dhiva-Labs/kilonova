import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kilonova/l10n/generated/app_localizations.dart';
import 'package:kilonova/theme/theme.dart';
import 'package:kilonova/widgets/copy_value.dart';
import 'package:kilonova/widgets/kn_field.dart';

/// Like `pumpThemed`, but with the localizations [CopyValue] and
/// [PasteButton] need for their tooltips, notices and dialog text.
Future<void> _pump(WidgetTester tester, Widget child) => tester.pumpWidget(
  MaterialApp(
    theme: buildTheme(Brightness.light),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: Padding(padding: const EdgeInsets.all(16), child: child),
    ),
  ),
);

/// A fake system clipboard: records what was set and answers `getData`
/// with it, like the real platform clipboard.
void _fakeClipboard(WidgetTester tester) {
  String? text;
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      switch (call.method) {
        case 'Clipboard.setData':
          text = (call.arguments as Map)['text'] as String?;
          return null;
        case 'Clipboard.getData':
          return text == null ? null : <String, dynamic>{'text': text};
        default:
          return null;
      }
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
}

void main() {
  group('CopyValue', () {
    testWidgets('copies the value and shows a snackbar', (tester) async {
      _fakeClipboard(tester);
      await _pump(tester, const CopyValue(label: 'Address', value: '4abc...'));
      expect(find.text('4abc...'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.copy_outlined));
      await tester.pump();

      final data = await Clipboard.getData(Clipboard.kTextPlain);
      expect(data?.text, '4abc...');
      expect(find.text('Address copied'), findsOneWidget);
    });

    testWidgets('a sensitive value asks before copying', (tester) async {
      _fakeClipboard(tester);
      await _pump(
        tester,
        const CopyValue(
          label: 'Secret spend key',
          value: 'deadbeef',
          sensitive: true,
        ),
      );

      await tester.tap(find.byIcon(Icons.copy_outlined));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Anyone who can read your clipboard can take your funds. '
          'Copy anyway?',
        ),
        findsOneWidget,
      );

      // Cancel: nothing is copied.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(await Clipboard.getData(Clipboard.kTextPlain), isNull);

      // Try again and confirm.
      await tester.tap(find.byIcon(Icons.copy_outlined));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy'));
      await tester.pumpAndSettle();

      final data = await Clipboard.getData(Clipboard.kTextPlain);
      expect(data?.text, 'deadbeef');
      expect(
        find.text('Copied. The clipboard clears in 60 seconds.'),
        findsOneWidget,
      );

      // Let the clear-later timer this started run out before the test
      // ends.
      await tester.pump(copySensitiveClearAfter);
    });

    testWidgets('clears a sensitive value from the clipboard after 60s', (
      tester,
    ) async {
      _fakeClipboard(tester);
      await _pump(
        tester,
        const CopyValue(
          label: 'Secret view key',
          value: 'cafef00d',
          sensitive: true,
        ),
      );

      await tester.tap(find.byIcon(Icons.copy_outlined));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy'));
      await tester.pumpAndSettle();
      expect((await Clipboard.getData(Clipboard.kTextPlain))?.text, 'cafef00d');

      await tester.pump(const Duration(seconds: 59));
      expect((await Clipboard.getData(Clipboard.kTextPlain))?.text, 'cafef00d');

      await tester.pump(const Duration(seconds: 2));
      expect((await Clipboard.getData(Clipboard.kTextPlain))?.text, '');
    });

    testWidgets('does not clear the clipboard if it changed since', (
      tester,
    ) async {
      _fakeClipboard(tester);
      await _pump(
        tester,
        const CopyValue(
          label: 'Secret view key',
          value: 'cafef00d',
          sensitive: true,
        ),
      );

      await tester.tap(find.byIcon(Icons.copy_outlined));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy'));
      await tester.pumpAndSettle();

      await Clipboard.setData(const ClipboardData(text: 'something else'));
      await tester.pump(const Duration(seconds: 61));
      expect(
        (await Clipboard.getData(Clipboard.kTextPlain))?.text,
        'something else',
      );
    });
  });

  group('PasteButton', () {
    testWidgets('fills the field with the trimmed clipboard text', (
      tester,
    ) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async => call.method == 'Clipboard.getData'
            ? <String, dynamic>{'text': '  pasted value  '}
            : null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      await _pump(
        tester,
        KnField(
          controller: controller,
          label: 'To',
          trailing: [PasteButton(controller: controller)],
        ),
      );
      await tester.tap(find.byTooltip('Paste'));
      await tester.pump();
      expect(controller.text, 'pasted value');
    });
  });
}
