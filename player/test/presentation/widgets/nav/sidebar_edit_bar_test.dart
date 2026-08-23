import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/widgets/nav/sidebar_edit_bar.dart';

Future<void> _pumpBar(
  WidgetTester tester, {
  required VoidCallback onDone,
  VoidCallback? onReset,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 260,
          child: SidebarEditBar(onDone: onDone, onReset: onReset),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Done calls onDone', (tester) async {
    var done = 0;
    await _pumpBar(tester, onDone: () => done++, onReset: () {});

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    expect(done, 1);
  });

  testWidgets('the reset action calls onReset', (tester) async {
    var reset = 0;
    await _pumpBar(tester, onDone: () {}, onReset: () => reset++);

    await tester.tap(find.byTooltip('Reset sidebar'));
    await tester.pumpAndSettle();

    expect(reset, 1);
  });

  testWidgets('labels the mode', (tester) async {
    await _pumpBar(tester, onDone: () {}, onReset: () {});

    expect(find.text('Editing'), findsOneWidget);
  });

  testWidgets('omits the reset control when onReset is null', (tester) async {
    await _pumpBar(tester, onDone: () {});

    expect(find.byTooltip('Reset sidebar'), findsNothing);
    expect(find.text('Done'), findsOneWidget);
  });

  testWidgets('the reset control keeps an accessible tap target',
      (tester) async {
    await _pumpBar(tester, onDone: () {}, onReset: () {});

    final tapTargetSize = tester.getSize(find.byTooltip('Reset sidebar'));

    expect(
      tapTargetSize.width,
      greaterThanOrEqualTo(SidebarEditBar.resetControlTapSize),
    );
    expect(
      tapTargetSize.height,
      greaterThanOrEqualTo(SidebarEditBar.resetControlTapSize),
    );
  });
}
