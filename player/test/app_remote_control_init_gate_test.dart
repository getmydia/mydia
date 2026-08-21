import 'package:flutter_test/flutter_test.dart';
import 'package:player/app.dart';

/// Pins the state-transition bug CodeRabbit found in
/// `_MyAppState._initRemoteControlIfEnabled`: it used to set its "attempted"
/// flag to `true` before doing any work, so a startup failure or an opt-out
/// disabled this device as a controllable target for the rest of the launch
/// — enabling the setting afterward needed a full app restart to take
/// effect.
///
/// `RemoteControlInitGate` is the extracted decision logic behind that
/// method. It is tested here in isolation, rather than through a widget
/// test that pumps `MyApp`, because `_initRemoteControlIfEnabled` itself
/// cannot be reached by one — its own dartdoc explains that it awaits
/// `DeviceInfoService.getDeviceName()`, which never completes inside a
/// `testWidgets` fake-async zone on Linux.
void main() {
  group('RemoteControlInitGate', () {
    test('allows an attempt before anything has run', () {
      final gate = RemoteControlInitGate();
      expect(gate.shouldAttempt, isTrue);
    });

    test('blocks a second, concurrent attempt while the first is in flight',
        () {
      final gate = RemoteControlInitGate();
      gate.begin();
      expect(gate.shouldAttempt, isFalse);
    });

    test(
        'allows a retry once an in-flight attempt ends without succeeding — '
        'an opt-out or a thrown startup failure', () {
      final gate = RemoteControlInitGate();
      gate.begin();
      gate.end();

      expect(gate.shouldAttempt, isTrue,
          reason: 'the bug this class fixes: a failed or opted-out attempt '
              'must not permanently disable this device as a target for '
              'the rest of the launch');
    });

    test('permanently blocks further attempts once one has succeeded', () {
      final gate = RemoteControlInitGate();
      gate.begin();
      gate.succeed();
      gate.end();

      expect(gate.shouldAttempt, isFalse,
          reason: 'a receiver that is already wired must not be wired a '
              'second time onto the same control-request stream');
    });

    test(
        'a later successful attempt after a failed one still latches '
        'closed', () {
      final gate = RemoteControlInitGate();
      gate.begin();
      gate.end(); // First attempt failed or opted out.

      expect(gate.shouldAttempt, isTrue);

      gate.begin();
      gate.succeed();
      gate.end();

      expect(gate.shouldAttempt, isFalse);
    });
  });
}
