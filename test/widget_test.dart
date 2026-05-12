// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:bytesized/main.dart';

void main() {
  // Initialize Supabase once for all tests in this file. This prevents
  // errors if widgets try to access Supabase.instance before it's ready.
  setUpAll(() async {
    // Use dummy values for testing. It's not necessary to connect to a real
    // Supabase instance for this widget smoke test.
    await Supabase.initialize(
      url: 'https://test.supabase.co',
      anonKey: 'test-key',
    );
  });

  testWidgets('App renders home screen smoke test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const ImageCompressorApp());

    // Wait for any animations or async state updates to finish (like _loadRecentFiles)
    await tester.pumpAndSettle();

    // Verify that the title is present.
    expect(find.text('ByteSized'), findsOneWidget);

    // Verify that the main action buttons are present.
    expect(find.text('Compress'), findsOneWidget);
    expect(find.text('Decompress'), findsOneWidget);
  });
}
