import 'package:flutter_test/flutter_test.dart';
import 'package:kilonova/features/settings/price_feed.dart';
import 'package:kilonova/src/rust/api/network.dart';
import 'package:kilonova/src/rust/api/price.dart';
import 'package:kilonova/src/rust/api/wallets.dart';

import '../../helpers/rust.dart';

void main() {
  setUpAll(initRustForTests);

  testWidgets('prices are off until a currency is chosen, then shown', (
    tester,
  ) async {
    useDesktopWindow(tester);
    var fetches = 0;
    final feed = PriceFeed(
      fetch: () async {
        fetches++;
        return 200;
      },
    );
    await tester.runAsync(() async {
      final seed = await generateSeed(format: SeedFormat.classic);
      (await createWalletFromSeed(
        name: 'Priced',
        network: Network.mainnet,
        mode: SyncMode.full,
        words: seed.words.join(' '),
        password: 'pw',
        createdHere: true,
      )).lock();
    });
    await tester.pumpWidget(await testApp(tester, price: feed));
    expect(await tester.runAsync(priceCurrency), isNull);
    expect(fetches, 0, reason: 'nothing is fetched while prices are off');

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Prices'));
    await tester.pumpAndSettle();
    expect(find.textContaining('api.coingecko.com'), findsOneWidget);
    await tester.tap(find.text('INR'));
    await pumpUntil(tester, () => fetches == 1, what: 'a price fetch');
    expect(await tester.runAsync(priceCurrency), 'inr');
    expect(feed.format(BigInt.from(1500000000000)), contains('300.00'));

    await tester.tap(find.text('Off'));
    await pumpUntil(tester, () => feed.currency == null, what: 'prices off');
    expect(feed.format(BigInt.one), isNull);
  });
}
