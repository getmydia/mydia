import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/playback/source_switch_gate.dart';

void main() {
  group('SourceSwitchGate', () {
    test('pass runs the call at once while the gate is open', () async {
      final gate = SourceSwitchGate();
      var ran = false;

      final passed = await gate.pass(() => true, () async {
        ran = true;
      });

      expect(passed, isTrue);
      expect(ran, isTrue);
    });

    test('pass waits while a switch holds the gate, then runs', () async {
      final gate = SourceSwitchGate();
      final replace = Completer<void>();
      final switched = gate.closeWhile(() => replace.future);
      var ran = false;

      final passed = gate.pass(() => true, () async {
        ran = true;
      });
      await pumpEventQueue();
      expect(ran, isFalse);

      replace.complete();
      await switched;
      expect(await passed, isTrue);
      expect(ran, isTrue);
    });

    test('stillWanted is asked after the wait, and a no skips the call',
        () async {
      final gate = SourceSwitchGate();
      final replace = Completer<void>();
      var wanted = true;
      final switched = gate.closeWhile(() async {
        await replace.future;
        wanted = false;
      });
      var ran = false;

      final passed = gate.pass(() => wanted, () async {
        ran = true;
      });
      replace.complete();
      await switched;

      expect(await passed, isFalse);
      expect(ran, isFalse);
    });

    test('a switch waits for a call already running before it replaces',
        () async {
      final gate = SourceSwitchGate();
      final call = Completer<void>();
      final passed = gate.pass(() => true, () => call.future);
      var replaced = false;

      final switched = gate.closeWhile(() async {
        replaced = true;
      });
      await pumpEventQueue();
      expect(replaced, isFalse);

      call.complete();
      await switched;
      expect(replaced, isTrue);
      expect(await passed, isTrue);
    });

    test('a call that throws reaches its caller and does not hold the gate',
        () async {
      final gate = SourceSwitchGate();
      final call = Completer<void>();
      final passed = gate.pass(() => true, () => call.future);
      final switched = gate.closeWhile(() async => 'replaced');

      call.completeError(StateError('[Player] has been disposed'));

      await expectLater(passed, throwsStateError);
      expect(await switched, 'replaced');
      expect(gate.closed, isFalse);
    });

    test('a switch that throws still reopens the gate', () async {
      final gate = SourceSwitchGate();
      final switched = gate.closeWhile<void>(
        () async => throw StateError('open failed'),
      );
      var ran = false;
      final passed = gate.pass(() => true, () async {
        ran = true;
      });

      await expectLater(switched, throwsStateError);
      expect(gate.closed, isFalse);
      expect(await passed, isTrue);
      expect(ran, isTrue);
    });

    test('closing a gate that is already closed is a StateError', () async {
      final gate = SourceSwitchGate();
      final replace = Completer<void>();
      final first = gate.closeWhile(() => replace.future);

      await expectLater(gate.closeWhile(() async {}), throwsStateError);

      replace.complete();
      await first;
    });

    test(
        'a waiter waits again when a new switch closes the gate before it '
        'resumes', () async {
      final gate = SourceSwitchGate();
      final first = Completer<void>();
      final second = Completer<void>();
      final switched = gate.closeWhile(() => first.future);
      Future<void>? secondSwitch;

      // Queued before the waiter below, so it resumes first when the gate
      // reopens and closes it again before the waiter gets to run.
      final opener = gate.pass(() => true, () async {
        secondSwitch = gate.closeWhile(() => second.future);
      });
      var ran = false;
      final waiter = gate.pass(() => true, () async {
        ran = true;
      });

      first.complete();
      await switched;
      await opener;
      await pumpEventQueue();
      expect(gate.closed, isTrue);
      expect(ran, isFalse);

      second.complete();
      await secondSwitch;
      expect(await waiter, isTrue);
      expect(ran, isTrue);
    });

    test('closes synchronously, so a check right after the call sees it',
        () async {
      final gate = SourceSwitchGate();
      final replace = Completer<void>();
      expect(gate.closed, isFalse);

      final switched = gate.closeWhile(() => replace.future);
      expect(gate.closed, isTrue);

      replace.complete();
      await switched;
      expect(gate.closed, isFalse);
    });
  });
}
