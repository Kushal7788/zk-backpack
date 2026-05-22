// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';

import 'package:zk_backpack_app/main.dart';

void main() {
  testWidgets('renders backpack shell', (WidgetTester tester) async {
    await tester.pumpWidget(const ZkBackpackApp());
    expect(find.text('ZK Backpack'), findsOneWidget);
    expect(find.text('Add'), findsOneWidget);
    expect(find.text('Vault'), findsOneWidget);
    expect(find.text('Verify'), findsOneWidget);
  });
}
