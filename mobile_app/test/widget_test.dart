import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app/main.dart';

void main() {
  testWidgets('IstanbulBizimApp launches smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const IstanbulBizimApp());
    expect(find.byType(IstanbulBizimApp), findsOneWidget);
  });
}
