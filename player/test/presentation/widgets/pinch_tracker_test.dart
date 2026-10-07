import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/video_scaling.dart';
import 'package:player/presentation/widgets/pinch_tracker.dart';

/// Two fingers 100px apart on a horizontal line, then spread to [endGap].
VideoScaling? _pinch(double endGap) {
  final t = PinchTracker()
    ..down(1, const Offset(100, 200))
    ..down(2, const Offset(200, 200))
    ..move(2, Offset(100 + endGap, 200));
  return t.up(2);
}

void main() {
  test('spreading past the fill ratio asks for fill', () {
    expect(_pinch(120), VideoScaling.fill);
  });

  test('pinching below the fit ratio asks for fit', () {
    expect(_pinch(80), VideoScaling.fit);
  });

  test('a small wobble inside the dead band asks for nothing', () {
    expect(_pinch(110), isNull);
    expect(_pinch(90), isNull);
  });

  test('a single finger is never a pinch', () {
    final t = PinchTracker()
      ..down(1, const Offset(100, 200))
      ..move(1, const Offset(400, 200));
    expect(t.up(1), isNull);
  });

  test('a third finger does not reset the pinch in progress', () {
    final t = PinchTracker()
      ..down(1, const Offset(100, 200))
      ..down(2, const Offset(200, 200))
      ..down(3, const Offset(500, 500))
      ..move(2, const Offset(250, 200));
    expect(t.up(2), VideoScaling.fill);
  });

  test('a cancelled finger ends the pinch with no result', () {
    final t = PinchTracker()
      ..down(1, const Offset(100, 200))
      ..down(2, const Offset(200, 200))
      ..move(2, const Offset(300, 200))
      ..cancel(2);
    expect(t.up(1), isNull);
  });

  test('reports once per pinch, on the first finger lifted', () {
    final t = PinchTracker()
      ..down(1, const Offset(100, 200))
      ..down(2, const Offset(200, 200))
      ..move(2, const Offset(300, 200));
    expect(t.up(2), VideoScaling.fill);
    expect(t.up(1), isNull);
  });

  test('pinching is false with one finger, true once the second lands', () {
    final t = PinchTracker()..down(1, const Offset(100, 200));
    expect(t.pinching, isFalse);
    t.down(2, const Offset(200, 200));
    expect(t.pinching, isTrue);
  });

  test('pinching is false after a lift', () {
    final t = PinchTracker()
      ..down(1, const Offset(100, 200))
      ..down(2, const Offset(200, 200));
    t.up(2);
    expect(t.pinching, isFalse);
  });

  test('pinching is false after a cancel', () {
    final t = PinchTracker()
      ..down(1, const Offset(100, 200))
      ..down(2, const Offset(200, 200))
      ..cancel(1);
    expect(t.pinching, isFalse);
  });
}
