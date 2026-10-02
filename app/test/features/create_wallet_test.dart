import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kilonova/widgets/seed_grid.dart';

import '../helpers/rust.dart';

void main() {
  setUpAll(initRustForTests);

  testWidgets('create a wallet, check the seed, set a password', (
    tester,
  ) async {
    useDesktopWindow(tester);
    await tester.pumpWidget(await testApp(tester));

    await tester.tap(find.widgetWithText(FilledButton, 'Create wallet'));
    await tester.pumpAndSettle();

    // Options: an empty name is refused.
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    await tester.pump();
    expect(find.text('Give the wallet a name.'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'Savings');
    await tester.tap(find.text('Classic, 25 words'));
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    await pumpUntilFound(tester, find.byType(SeedGrid));

    final grid = tester.widget<SeedGrid>(find.byType(SeedGrid));
    expect(grid.words, hasLength(25));
    final words = List.of(grid.words);

    await tester.tap(find.text('I wrote them down'));
    await tester.pumpAndSettle();

    // A wrong word is refused.
    final prompts = tester
        .widgetList<TextField>(find.byType(TextField))
        .map((f) => f.decoration!.labelText!)
        .toList();
    expect(prompts, hasLength(3));
    final positions = [
      for (final p in prompts) int.parse(p.replaceAll(RegExp(r'\D'), '')),
    ];
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'wrong');
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    await tester.pump();
    expect(
      find.text('That word does not match. Check what you wrote down.'),
      findsOneWidget,
    );

    for (var i = 0; i < 3; i++) {
      await tester.enterText(fields.at(i), words[positions[i] - 1]);
    }
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    await tester.pumpAndSettle();

    // Password rules.
    final pw = find.byType(TextFormField);
    await tester.enterText(pw.at(0), 'short');
    await tester.enterText(pw.at(1), 'short');
    await tester.tap(find.widgetWithText(FilledButton, 'Create wallet'));
    await tester.pump();
    expect(find.text('Use at least 8 characters.'), findsOneWidget);

    await tester.enterText(pw.at(0), 'correct horse');
    await tester.enterText(pw.at(1), 'correct horse battery');
    await tester.tap(find.widgetWithText(FilledButton, 'Create wallet'));
    await tester.pump();
    expect(find.text('The passwords do not match.'), findsOneWidget);

    await tester.enterText(pw.at(1), 'correct horse');
    await tester.tap(find.widgetWithText(FilledButton, 'Create wallet'));
    await pumpUntilFound(tester, find.text('Balance'));

    // Back on the wallet list, opened beside it.
    expect(find.text('Savings'), findsWidgets);
    expect(find.text('Receive'), findsOneWidget);
    final address = tester.widget<SelectableText>(
      find.byType(SelectableText).first,
    );
    expect(address.data, startsWith('4'));
  });
}
