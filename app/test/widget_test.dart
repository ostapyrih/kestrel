import 'package:flutter_test/flutter_test.dart';
import 'package:kestrel/main.dart';

void main() {
  testWidgets('shows Kestrel home screen', (WidgetTester tester) async {
    await tester.pumpWidget(const KestrelApp());
    expect(find.text('Kestrel'), findsWidgets);
  });
}
