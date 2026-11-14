import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/media_probe.dart';
import 'package:player/core/player/mpv_probe_mapping.dart';
import 'package:player/core/sources/files/backend/file_system_backend.dart';

class _FakeProbe implements MediaProbe {
  final List<PlayableFile> started = [];
  final List<Completer<ProbeResult?>> completers = [];

  @override
  Future<ProbeResult?> probe(
    PlayableFile playable, {
    Duration timeout = const Duration(seconds: 15),
  }) {
    started.add(playable);
    final c = Completer<ProbeResult?>();
    completers.add(c);
    return c.future;
  }
}

class _ThrowingProbe implements MediaProbe {
  int calls = 0;

  @override
  Future<ProbeResult?> probe(
    PlayableFile playable, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    calls++;
    if (calls == 1) throw StateError('boom');
    return const ProbeResult(container: 'mkv');
  }
}

void main() {
  const a = PlayableFile(url: 'file:///a.mkv');
  const b = PlayableFile(url: 'file:///b.mkv');

  test('runs one probe at a time', () async {
    final inner = _FakeProbe();
    final serialized = SerializedMediaProbe(inner);

    final first = serialized.probe(a);
    final second = serialized.probe(b);
    await pumpEventQueue();
    expect(inner.started, [a]);

    inner.completers[0].complete(const ProbeResult(container: 'mkv'));
    expect((await first)?.container, 'mkv');
    await pumpEventQueue();
    expect(inner.started, [a, b]);

    inner.completers[1].complete(null);
    expect(await second, isNull);
  });

  test('a throwing inner probe releases the lock and returns null', () async {
    final inner = _ThrowingProbe();
    final serialized = SerializedMediaProbe(inner);

    expect(await serialized.probe(a), isNull);
    expect((await serialized.probe(b))?.container, 'mkv');
  });
}
