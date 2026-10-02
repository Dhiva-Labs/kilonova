import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kilonova/app.dart';
import 'package:kilonova/src/rust/frb_generated.dart';

/// Runs the real app with the Rust core built by the platform toolchain,
/// proving the flutter_rust_bridge wiring end to end.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(RustLib.init);

  testWidgets('app boots and reads the network list from Rust', (tester) async {
    await tester.pumpWidget(const KilonovaApp());

    expect(find.text('Mainnet'), findsOneWidget);
    expect(find.text('Stagenet'), findsOneWidget);
    expect(find.text('Testnet'), findsOneWidget);
  });

  testWidgets('privacy policy renders from the bundled asset', (tester) async {
    await tester.pumpWidget(const KilonovaApp());

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Privacy policy'));
    await tester.pumpAndSettle();

    expect(find.text('Kilonova privacy policy'), findsOneWidget);
  });
}
