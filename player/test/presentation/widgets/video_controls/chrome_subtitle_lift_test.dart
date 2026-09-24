import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/subtitle_position.dart';
import 'package:player/core/theme/depth_tokens.dart';
import 'package:player/presentation/widgets/video_controls/chrome_subtitle_lift.dart';
import 'package:player/presentation/widgets/video_controls/playback_chrome.dart';

class _RecordingLift implements SubtitleLift {
  final bottoms = <double>[];
  final durations = <Duration>[];

  @override
  void apply(double bottom, {required Duration duration}) {
    bottoms.add(bottom);
    durations.add(duration);
  }
}

/// A lift with value equality on [id], so a freshly-constructed instance
/// with the same id compares `==` to a previous one -- the shape
/// `VideoStateSubtitleLift(state)` takes when it is built inline on every
/// `PlaybackChrome` rebuild.
class _EqualLift implements SubtitleLift {
  _EqualLift(this.id, this.calls);

  final int id;
  final List<double> calls;

  @override
  void apply(double bottom, {required Duration duration}) => calls.add(bottom);

  @override
  bool operator ==(Object other) => other is _EqualLift && other.id == id;

  @override
  int get hashCode => id;
}

/// A child with its own State, to prove [ChromeSubtitleLift] never changes
/// the element shape above it (which would remount and drop this State).
class _CountingChild extends StatefulWidget {
  const _CountingChild();

  @override
  State<_CountingChild> createState() => _CountingChildState();
}

class _CountingChildState extends State<_CountingChild> {
  @override
  Widget build(BuildContext context) => const SizedBox();
}

final _reference = GlobalKey();

RenderBox? _referenceBox() =>
    _reference.currentContext?.findRenderObject() as RenderBox?;

/// A 1400x900 view with a panel of [panelHeight] 16px off the bottom edge,
/// like the real chrome's `Positioned(bottom: metrics.bottomOffset)`.
Widget _host({
  required SubtitleLift? lift,
  Animation<double>? chrome,
  double panelHeight = 120,
  Widget? child,
}) {
  final stack = Stack(
    key: _reference,
    fit: StackFit.expand,
    children: [
      Positioned(
        left: 0,
        right: 0,
        bottom: 16,
        child: ChromeSubtitleLift(
          lift: lift,
          referenceBox: _referenceBox,
          child: child ?? SizedBox(height: panelHeight),
        ),
      ),
    ],
  );
  return MaterialApp(
    home: chrome == null
        ? stack
        : ChromeAnimation(animation: chrome, child: stack),
  );
}

void _view(WidgetTester tester) {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

// Panel top = 900 - 16 - 120 = 764, so the lift is 900 - 764 + 12.
const double _shownLift = 148;

void main() {
  late AnimationController chrome;

  setUp(() {
    chrome = AnimationController(
      vsync: const TestVSync(),
      duration: const Duration(milliseconds: 200),
      value: 1,
    );
  });

  tearDown(() => chrome.dispose());

  testWidgets('lifts clear of the panel while the chrome is shown',
      (tester) async {
    _view(tester);
    final lift = _RecordingLift();
    await tester.pumpWidget(_host(lift: lift, chrome: chrome));
    await tester.pump();

    expect(lift.bottoms, [_shownLift]);
    expect(lift.durations, [DepthTokens.motionFast]);
  });

  testWidgets('drops to rest as a hide starts, and back up on show',
      (tester) async {
    _view(tester);
    final lift = _RecordingLift();
    await tester.pumpWidget(_host(lift: lift, chrome: chrome));
    await tester.pump();

    chrome.reverse();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(chrome.status, AnimationStatus.reverse);
    expect(lift.bottoms.last, kSubtitleRestPadding);
    expect(lift.durations.last, DepthTokens.motionMedium);

    await tester.pumpAndSettle();
    chrome.forward();
    await tester.pumpAndSettle();
    expect(lift.bottoms, [_shownLift, kSubtitleRestPadding, _shownLift]);
  });

  testWidgets('follows a panel resize without repeating itself',
      (tester) async {
    _view(tester);
    final lift = _RecordingLift();
    await tester.pumpWidget(_host(lift: lift, chrome: chrome));
    await tester.pump();

    await tester
        .pumpWidget(_host(lift: lift, chrome: chrome, panelHeight: 200));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // Panel top = 900 - 16 - 200 = 684.
    expect(lift.bottoms, [_shownLift, 228]);
  });

  testWidgets('returns to rest when unmounted', (tester) async {
    _view(tester);
    final lift = _RecordingLift();
    await tester.pumpWidget(_host(lift: lift, chrome: chrome));
    await tester.pump();

    await tester.pumpWidget(const SizedBox());
    await tester.pump();

    expect(lift.bottoms, [_shownLift, kSubtitleRestPadding]);
  });

  testWidgets('counts as shown with no chrome animation above it',
      (tester) async {
    _view(tester);
    final lift = _RecordingLift();
    await tester.pumpWidget(_host(lift: lift));
    await tester.pump();

    expect(lift.bottoms, [_shownLift]);
  });

  testWidgets('does nothing without a lift', (tester) async {
    _view(tester);
    await tester.pumpWidget(_host(lift: null, chrome: chrome));
    await tester.pump();

    expect(find.byType(SizedBox), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('swapping lift non-null -> null resets the old lift to rest',
      (tester) async {
    _view(tester);
    final lift = _RecordingLift();
    await tester.pumpWidget(_host(lift: lift, chrome: chrome));
    await tester.pump();
    expect(lift.bottoms, [_shownLift]);

    await tester.pumpWidget(_host(lift: null, chrome: chrome));
    await tester.pump();

    expect(lift.bottoms, [_shownLift, kSubtitleRestPadding]);
    expect(lift.durations.last, DepthTokens.motionMedium);
  });

  testWidgets(
      'swapping lift null -> non-null picks up the shown lift, then rest on hide',
      (tester) async {
    _view(tester);
    await tester.pumpWidget(_host(lift: null, chrome: chrome));
    await tester.pump();

    final lift = _RecordingLift();
    await tester.pumpWidget(_host(lift: lift, chrome: chrome));
    await tester.pump();
    expect(lift.bottoms, [_shownLift]);

    chrome.reverse();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(chrome.status, AnimationStatus.reverse);
    expect(lift.bottoms.last, kSubtitleRestPadding);
    await tester.pumpAndSettle();
  });

  testWidgets(
      'rebuilding with an equal-but-different lift instance does not re-apply',
      (tester) async {
    _view(tester);
    final calls = <double>[];
    await tester.pumpWidget(_host(lift: _EqualLift(1, calls), chrome: chrome));
    await tester.pump();
    expect(calls, [_shownLift]);

    await tester.pumpWidget(_host(lift: _EqualLift(1, calls), chrome: chrome));
    await tester.pump();

    expect(calls, [_shownLift]);
  });

  testWidgets('toggling lift null <-> non-null keeps the child State',
      (tester) async {
    _view(tester);
    const child = _CountingChild();
    await tester.pumpWidget(_host(lift: null, chrome: chrome, child: child));
    await tester.pump();
    final before =
        tester.state<_CountingChildState>(find.byType(_CountingChild));

    final lift = _RecordingLift();
    await tester.pumpWidget(_host(lift: lift, chrome: chrome, child: child));
    await tester.pump();
    final after =
        tester.state<_CountingChildState>(find.byType(_CountingChild));

    expect(identical(before, after), isTrue);
  });
}
