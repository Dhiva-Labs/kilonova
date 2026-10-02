import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kilonova/src/rust/api/nodes.dart';

import '../../helpers/rust.dart';

void main() {
  setUpAll(initRustForTests);

  testWidgets('only a proxy that answers is saved', (tester) async {
    useDesktopWindow(tester);
    await tester.pumpWidget(await testApp(tester));
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Proxy and Tor'));
    await pumpUntilFound(
      tester,
      find.text('Not set. Kilonova connects directly.'),
    );

    await tester.enterText(find.byType(TextField), 'http://127.0.0.1:9050');
    await tester.tap(find.text('Check and use'));
    await pumpUntilFound(
      tester,
      find.text(
        'Not a proxy address. Use host:port, for example 127.0.0.1:9050.',
      ),
    );

    // Nothing listens on port 1.
    await tester.enterText(find.byType(TextField), '127.0.0.1:1');
    await tester.tap(find.text('Check and use'));
    await pumpUntil(
      tester,
      () => find.text('Checking that the proxy answers').evaluate().isEmpty,
      what: 'the check to finish',
    );
    expect(find.text('Not set. Kilonova connects directly.'), findsOneWidget);
    expect(await tester.runAsync(networkProxy), isNull);

    await tester.tap(find.text("Fill in Tor's address"));
    await tester.pump();
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, '127.0.0.1:9050');
  });
}
