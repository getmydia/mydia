import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/build_channel.dart';
import 'package:player/presentation/widgets/channel_badge.dart';

Widget _host(BuildChannel channel) => MaterialApp(
      home: Scaffold(body: Center(child: ChannelBadge(channel: channel))),
    );

void main() {
  testWidgets('renders nothing on stable', (tester) async {
    await tester.pumpWidget(_host(BuildChannel.stable));
    expect(find.byKey(const ValueKey('channel-badge')), findsNothing);
  });

  testWidgets('shows BETA on beta', (tester) async {
    await tester.pumpWidget(_host(BuildChannel.beta));
    expect(find.byKey(const ValueKey('channel-badge')), findsOneWidget);
    expect(find.text('BETA'), findsOneWidget);
  });

  testWidgets('shows DEV on dev', (tester) async {
    await tester.pumpWidget(_host(BuildChannel.dev));
    expect(find.text('DEV'), findsOneWidget);
  });

  testWidgets('is not focusable', (tester) async {
    await tester.pumpWidget(_host(BuildChannel.dev));
    final focusables = find.descendant(
      of: find.byKey(const ValueKey('channel-badge')),
      matching: find.byType(Focus),
    );
    expect(focusables, findsNothing);
  });
}
