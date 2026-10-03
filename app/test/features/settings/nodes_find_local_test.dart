import 'package:flutter_test/flutter_test.dart';
import 'package:kilonova/src/rust/api/nodes.dart';

import '../../helpers/rust.dart';

void main() {
  setUpAll(initRustForTests);

  testWidgets('looking for local nodes is off while a proxy is set', (
    tester,
  ) async {
    useDesktopWindow(tester);
    await tester.runAsync(() => setNetworkProxy(url: '127.0.0.1:9050'));
    addTearDown(() => setNetworkProxy());

    await tester.pumpWidget(await testApp(tester));
    await openSettings(tester);
    await tester.tap(find.text('Nodes'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Find nodes on this network'));
    await pumpUntilFound(
      tester,
      find.text(
        'Looking on the local network would go around your proxy, so it is off while a proxy is set.',
      ),
    );
  });
}
