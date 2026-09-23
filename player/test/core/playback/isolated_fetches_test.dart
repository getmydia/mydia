import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/playback/isolated_fetches.dart';

void main() {
  test('runs every task concurrently', () async {
    final gates = [Completer<void>(), Completer<void>()];
    final started = <String>[];
    final done = runIsolated({
      'a': () async {
        started.add('a');
        await gates[0].future;
      },
      'b': () async {
        started.add('b');
        await gates[1].future;
      },
    });
    await pumpEventQueue();
    expect(started, ['a', 'b']);
    gates[0].complete();
    gates[1].complete();
    await done;
  });

  test('a failing task is logged and does not stop the others', () async {
    final lines = <String>[];
    var bFinished = false;
    await runIsolated({
      'a': () async => throw StateError('boom'),
      'b': () async => bFinished = true,
    }, log: lines.add);
    expect(bFinished, isTrue);
    expect(lines.single, contains('a'));
  });
}
