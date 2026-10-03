import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kilonova/features/wallet/history_list.dart';
import 'package:kilonova/l10n/generated/app_localizations.dart';
import 'package:kilonova/src/rust/api/sync.dart';
import 'package:kilonova/theme/theme.dart';
import 'package:kilonova/widgets/kn_card.dart' show KnRow;

HistoryItem _item(int i) => HistoryItem(
  txHash: 'tx$i',
  height: BigInt.from(1000 + i),
  incoming: i.isEven,
  amount: BigInt.from(1000000000 + i),
  miner: false,
  locked: false,
  subaddressIndex: 0,
  pending: false,
  note: null,
  sentTo: i.isEven ? null : 'addr$i',
);

Future<void> _pump(WidgetTester tester, List<HistoryItem> items) {
  return tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        // A fixed-height viewport, as the real wallet page has: the
        // history is one of several sections sharing the screen.
        body: SizedBox(
          height: 600,
          child: CustomScrollView(
            slivers: [HistoryList(items: items)],
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets(
    'a long history only builds the rows near the viewport',
    (tester) async {
      await _pump(tester, List.generate(2000, _item));

      // Only a handful of rows fit a 600px window (each row is at least
      // 52px, plus Flutter's default cache extent beyond it); nowhere
      // near all 2000 should ever be built at once.
      final builtRows = find.byType(KnRow).evaluate().length;
      expect(builtRows, lessThan(60));
      expect(builtRows, greaterThan(0));
    },
  );

  testWidgets('scrolling builds further rows without building everything', (
    tester,
  ) async {
    await _pump(tester, List.generate(2000, _item));
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -20000));
    await tester.pumpAndSettle();

    final builtRows = find.byType(KnRow).evaluate().length;
    expect(builtRows, lessThan(60));
  });

  testWidgets('an empty history shows one line, no card', (tester) async {
    await _pump(tester, const []);

    expect(find.byType(KnRow), findsNothing);
    expect(find.text('No transactions yet.'), findsOneWidget);
  });
}
