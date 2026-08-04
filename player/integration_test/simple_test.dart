import 'package:flutter_test/flutter_test.dart';
import 'package:player/app.dart';
import 'package:integration_test/integration_test.dart';

import 'helpers/test_bootstrap.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(ensureTestBootstrap);
  testWidgets('Can call rust function', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());
    expect(find.textContaining('Result: `Hello, Tom!`'), findsOneWidget);
  });
}
