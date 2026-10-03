import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/screens/player/player_screen_views.dart';

void main() {
  testWidgets('loading view shows the message under the spinner',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: PlayerLoadingView(message: 'Starting stream'),
    ));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Starting stream'), findsOneWidget);
  });

  testWidgets('loading view without a message shows only the spinner',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: PlayerLoadingView()));
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('error view retries', (tester) async {
    var retried = 0;
    await tester.pumpWidget(MaterialApp(
      home: PlayerErrorView(message: 'Codec refused', onRetry: () => retried++),
    ));
    expect(find.text('Failed to load video'), findsOneWidget);
    expect(find.text('Codec refused'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    expect(retried, 1);
  });
}
