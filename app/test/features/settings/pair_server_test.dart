import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kilonova/src/rust/api/network.dart';
import 'package:kilonova/src/rust/api/nodes.dart';

import '../../helpers/rust.dart';

const _code =
    'kilonova-server:?network=stagenet&node=http%3A%2F%2Fexample.onion%3A18089'
    '&lws=http%3A%2F%2Fexample.onion%3A8443';

void main() {
  setUpAll(initRustForTests);

  testWidgets('pasting an onion pairing code asks to turn on Tor', (
    tester,
  ) async {
    useDesktopWindow(tester);
    await tester.pumpWidget(await testApp(tester));
    await openSettings(tester);
    await tester.tap(find.text('Pair with your server'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), _code);
    await tester.tap(find.text('Pair'));
    await pumpUntilFound(
      tester,
      find.text(
        'These are onion addresses. Turn on Tor under Proxy and Tor to reach them.',
      ),
    );

    final saved = await tester.runAsync(
      () => lwsServer(network: Network.stagenet),
    );
    expect(saved, contains('example.onion'));
  });
}
