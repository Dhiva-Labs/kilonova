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

  testWidgets('real onion addresses fit on a phone', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(await testApp(tester));
    await openSettings(tester);
    await tester.tap(find.text('Pair with your server'));
    await tester.pumpAndSettle();

    const onion =
        'ciczdlujjvdfuvwndzmqpefmndzxelyh3cbip4eqwet6it3tmuwgh2ad.onion';
    await tester.enterText(
      find.byType(TextField),
      'kilonova-server:?network=testnet'
      '&node=http%3A%2F%2F$onion%3A18089&lws=http%3A%2F%2F$onion%3A8443'
      '&push=http%3A%2F%2F$onion',
    );
    await tester.tap(find.text('Pair'));
    await pumpUntilFound(tester, find.text('PUSH'));
    expect(tester.takeException(), isNull);
  });
}
