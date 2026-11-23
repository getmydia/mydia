import 'dart:async';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/player_exit_guard.dart';

void main() {
  late PlayerExitGuard guard;

  setUp(() => guard = PlayerExitGuard());

  test('an exit request releases every registered player first', () async {
    final released = <String>[];
    guard
      ..register(() async => released.add('a'))
      ..register(() async => released.add('b'));

    final response = await guard.onExitRequested();

    expect(released, unorderedEquals(['a', 'b']));
    expect(response, AppExitResponse.exit);
  });

  test('an unregistered player is not released', () async {
    final released = <String>[];
    final handle = guard.register(() async => released.add('gone'));
    guard.register(() async => released.add('kept'));

    handle.unregister();
    await guard.onExitRequested();

    expect(released, ['kept']);
  });

  test('exit waits for a release to finish', () async {
    final gate = Completer<void>();
    var finished = false;
    guard.register(() async {
      await gate.future;
      finished = true;
    });

    var answered = false;
    final response = guard.onExitRequested().then((r) {
      answered = true;
      return r;
    });
    await pumpEventQueue();
    expect(answered, isFalse);

    gate.complete();
    expect(await response, AppExitResponse.exit);
    expect(finished, isTrue);
  });

  test('a release that hangs or throws never blocks the exit', () async {
    guard = PlayerExitGuard(timeout: const Duration(milliseconds: 50));
    guard
      ..register(() => Completer<void>().future)
      ..register(() async => throw StateError('boom'));

    expect(await guard.onExitRequested(), AppExitResponse.exit);
  });

  test('exit waits for a dispose that is already under way', () async {
    final gate = Completer<void>();
    unawaited(guard.track(gate.future));

    var answered = false;
    final response = guard.onExitRequested().then((r) {
      answered = true;
      return r;
    });
    await pumpEventQueue();
    expect(answered, isFalse);

    gate.complete();
    expect(await response, AppExitResponse.exit);
  });

  test('a player registered while the exit waits is released before the '
      'exit answers', () async {
    final gate = Completer<void>();
    guard.register(() => gate.future);
    final response = guard.onExitRequested();
    await pumpEventQueue();

    var lateReleased = false;
    guard.register(() async => lateReleased = true);
    gate.complete();

    expect(await response, AppExitResponse.exit);
    expect(lateReleased, isTrue);
  });

  test('a hung tracked dispose never blocks the exit', () async {
    guard = PlayerExitGuard(timeout: const Duration(milliseconds: 50));
    unawaited(guard.track(Completer<void>().future));

    expect(await guard.onExitRequested(), AppExitResponse.exit);
  });

  test('with nothing registered the exit is immediate', () async {
    expect(await guard.onExitRequested(), AppExitResponse.exit);
  });
}
