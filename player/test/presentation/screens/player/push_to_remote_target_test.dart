// Unit coverage for `pushToRemoteTarget`, the ordering behind "Push":
// capture position and track selections, `Hello`, `LoadContent`, and only
// stop local playback once the receiver has actually confirmed the load.
//
// Extracted from `_showCastDevicePicker` and tested here rather than through
// the widget for the reason spelled out on the function itself: this suite
// can never construct a real, *playing* media_kit `Player` under
// `flutter test` (see `shouldRestartForSeek`'s dartdoc in player_screen.dart),
// so there is no way to watch local playback "keep running" through the
// widget. The ordering itself — stopLocal never runs unless startCast
// resolved — is what stands in for that observation, same precedent as
// `quality_choice_test.dart` and `seek_restart_decision_test.dart`.

import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/screens/player/player_screen.dart';

void main() {
  group('pushToRemoteTarget', () {
    test('stops local playback only after a successful cast', () async {
      final order = <String>[];

      await pushToRemoteTarget(
        startCast: () async => order.add('startCast'),
        stopLocal: () async => order.add('stopLocal'),
      );

      expect(order, ['startCast', 'stopLocal'],
          reason: 'the receiver has to confirm the load before local '
              'playback is allowed to stop');
    });

    test(
        'a failed cast leaves local playback running: stopLocal is never '
        'called and the failure propagates', () async {
      var stopLocalCalled = false;
      final failure = Exception('unreachable receiver');

      await expectLater(
        pushToRemoteTarget(
          startCast: () async => throw failure,
          stopLocal: () async => stopLocalCalled = true,
        ),
        throwsA(same(failure)),
        reason: 'the caller (_showCastDevicePicker) has to see this to show '
            'its own error snackbar instead of silently swallowing it',
      );

      expect(stopLocalCalled, isFalse,
          reason: 'this is the whole point: a failed LoadContent must not '
              'stop whatever the viewer was already watching locally');
    });

    test(
        'a cast that throws asynchronously, mid-negotiation, still leaves '
        'local playback alone', () async {
      // `startCast` awaits a real network round trip (connect, resolve
      // route, LOAD) before it can fail — this proves the guarantee holds
      // for a failure that arrives well after the call started, not just
      // one that throws synchronously.
      var stopLocalCalled = false;

      await expectLater(
        pushToRemoteTarget(
          startCast: () async {
            await Future<void>.delayed(Duration.zero);
            await Future<void>.delayed(Duration.zero);
            throw StateError('receiver rejected the codec');
          },
          stopLocal: () async => stopLocalCalled = true,
        ),
        throwsA(isA<StateError>()),
      );

      expect(stopLocalCalled, isFalse);
    });
  });
}
