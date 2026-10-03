import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kilonova/src/rust/api/preferences.dart';

import '../../helpers/rust.dart';

void main() {
  setUpAll(initRustForTests);

  testWidgets('the confirm-payments toggle saves the preference', (
    tester,
  ) async {
    useDesktopWindow(tester);
    await tester.pumpWidget(await testApp(tester));
    await openSettings(tester);
    await tester.tap(find.text('Light wallet servers'));
    await tester.pumpAndSettle();

    await pumpUntilFound(tester, find.byType(Switch));
    await pumpUntil(
      tester,
      () => tester.widget<Switch>(find.byType(Switch)).onChanged != null,
      what: 'the preference to load',
    );
    // On by default: lookups are hidden among cover lookups.
    expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);

    await tester.tap(find.byType(Switch));
    await pumpUntil(
      tester,
      () => !tester.widget<Switch>(find.byType(Switch)).value,
      what: 'the switch to flip',
    );

    final saved = await tester.runAsync(preferences);
    expect(saved!.confirmLwsPayments, isFalse);
    // The other preference fields are untouched.
    expect(saved.notifyIncoming, isFalse);
  });
}
