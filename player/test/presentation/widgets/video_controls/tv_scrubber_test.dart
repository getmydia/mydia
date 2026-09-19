import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/scrub_controller.dart';
import 'package:player/presentation/widgets/video_controls/tv_scrubber.dart';

void main() {
  late Duration clock;
  late Duration runtime;
  late List<Duration> commits;
  late List<LogicalKeyboardKey> reachedParent;
  late int playPauses;
  late ScrubController scrub;
  late FocusNode barFocus;
  late FocusNode otherFocus;

  setUp(() {
    clock = Duration.zero;
    runtime = const Duration(hours: 1);
    commits = [];
    reachedParent = [];
    playPauses = 0;
    barFocus = FocusNode(debugLabel: 'bar');
    otherFocus = FocusNode(debugLabel: 'other');
  });

  Future<void> pump(WidgetTester tester) async {
    scrub = ScrubController(
      position: () => const Duration(minutes: 10),
      duration: () => runtime,
      onCommit: (target) async => commits.add(target),
      elapsed: () => clock,
    );
    await tester.pumpWidget(MaterialApp(
      home: Focus(
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent) reachedParent.add(event.logicalKey);
          return KeyEventResult.ignored;
        },
        child: Column(
          children: [
            TvScrubber(
              scrub: scrub,
              focusNode: barFocus,
              onPlayPause: () => playPauses++,
              builder: (context, focused) => SizedBox(
                key: ValueKey('bar-focused-$focused'),
                width: 400,
                height: 32,
              ),
            ),
            Focus(
              focusNode: otherFocus,
              child: const SizedBox(width: 400, height: 32),
            ),
          ],
        ),
      ),
    ));
    barFocus.requestFocus();
    // One pump applies the focus change, the next rebuilds the bar with it.
    await tester.pump();
    await tester.pump();
  }

  /// Unmounts before disposing, so no focus change reaches a disposed
  /// controller, and so no idle or settling timer outlives the test.
  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    scrub.dispose();
    barFocus.dispose();
    otherFocus.dispose();
  }

  Future<bool> press(WidgetTester tester, LogicalKeyboardKey key) async {
    final handled = await tester.sendKeyDownEvent(key);
    await tester.sendKeyUpEvent(key);
    return handled;
  }

  testWidgets('tells the builder when the bar holds focus', (tester) async {
    await pump(tester);

    expect(find.byKey(const ValueKey('bar-focused-true')), findsOneWidget);
    await finish(tester);
  });

  testWidgets('right starts a scrub and is handled', (tester) async {
    await pump(tester);

    expect(await press(tester, LogicalKeyboardKey.arrowRight), isTrue);

    expect(scrub.cursor, const Duration(minutes: 10, seconds: 10));
    expect(reachedParent, isEmpty);
    await finish(tester);
  });

  testWidgets('a held key moves by repeat speed, not by step', (tester) async {
    await pump(tester);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
    clock += const Duration(milliseconds: 100);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);

    // 10 s for the press, then 100 ms held at 30x.
    expect(scrub.cursor, const Duration(minutes: 10, seconds: 13));
    await finish(tester);
  });

  testWidgets('OK commits the cursor', (tester) async {
    await pump(tester);
    await press(tester, LogicalKeyboardKey.arrowRight);

    expect(await press(tester, LogicalKeyboardKey.select), isTrue);

    expect(commits, [const Duration(minutes: 10, seconds: 10)]);
    expect(scrub.active, isFalse);
    await finish(tester);
  });

  // The fall-through tests assert on what reached the parent, not on the
  // return value of sendKeyDownEvent: once the parent ignores a key,
  // MaterialApp's default shortcuts may still report it handled.
  testWidgets('OK with no scrub is left to the parent', (tester) async {
    await pump(tester);

    await press(tester, LogicalKeyboardKey.select);

    expect(reachedParent, [LogicalKeyboardKey.select]);
    expect(commits, isEmpty);
    await finish(tester);
  });

  testWidgets('Play/Pause commits and then toggles', (tester) async {
    await pump(tester);
    await press(tester, LogicalKeyboardKey.arrowRight);

    expect(await press(tester, LogicalKeyboardKey.mediaPlayPause), isTrue);

    expect(commits, [const Duration(minutes: 10, seconds: 10)]);
    expect(playPauses, 1);
    await finish(tester);
  });

  testWidgets('Play/Pause with no scrub is left to the parent', (tester) async {
    await pump(tester);

    await press(tester, LogicalKeyboardKey.mediaPlayPause);

    expect(reachedParent, [LogicalKeyboardKey.mediaPlayPause]);
    expect(playPauses, 0);
    await finish(tester);
  });

  testWidgets('up commits and still reaches the parent', (tester) async {
    await pump(tester);
    await press(tester, LogicalKeyboardKey.arrowRight);

    await press(tester, LogicalKeyboardKey.arrowUp);

    expect(commits, [const Duration(minutes: 10, seconds: 10)]);
    expect(reachedParent, contains(LogicalKeyboardKey.arrowUp));
    await finish(tester);
  });

  testWidgets('losing focus commits', (tester) async {
    await pump(tester);
    await press(tester, LogicalKeyboardKey.arrowRight);

    otherFocus.requestFocus();
    await tester.pump();

    expect(commits, [const Duration(minutes: 10, seconds: 10)]);
    await finish(tester);
  });

  testWidgets('with the runtime unknown, arrows fall through', (tester) async {
    runtime = Duration.zero;
    await pump(tester);

    await press(tester, LogicalKeyboardKey.arrowRight);

    expect(scrub.active, isFalse);
    expect(reachedParent, [LogicalKeyboardKey.arrowRight]);
    await finish(tester);
  });
}
