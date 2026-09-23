import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:player/core/player/tracks_ready.dart';

const _probed = Tracks(
  video: [
    VideoTrack('auto', null, null),
    VideoTrack('no', null, null),
    VideoTrack('1', null, null)
  ],
  audio: [
    AudioTrack('auto', null, null),
    AudioTrack('no', null, null),
    AudioTrack('1', null, 'eng')
  ],
);

void main() {
  test('the default Tracks holds only pseudo-tracks', () {
    expect(hasRealTracks(const Tracks()), isFalse);
    expect(hasRealTracks(_probed), isTrue);
  });

  test('returns at once when tracks are already known', () async {
    expect(
      await awaitRealTracks(current: _probed, updates: const Stream.empty()),
      isTrue,
    );
  });

  test('returns on the first event with real tracks', () async {
    final updates = StreamController<Tracks>();
    final result =
        awaitRealTracks(current: const Tracks(), updates: updates.stream);
    updates.add(const Tracks());
    updates.add(_probed);
    expect(await result, isTrue);
    await updates.close();
  });

  test('gives up after the timeout', () {
    fakeAsync((async) {
      bool? result;
      awaitRealTracks(
        current: const Tracks(),
        updates: StreamController<Tracks>().stream,
        timeout: const Duration(seconds: 3),
      ).then((value) => result = value);
      async.elapse(const Duration(seconds: 3));
      expect(result, isFalse);
    });
  });

  test('cancels the subscription on the stream after a timeout', () {
    fakeAsync((async) {
      final controller = StreamController<Tracks>();
      awaitRealTracks(
        current: const Tracks(),
        updates: controller.stream,
        timeout: const Duration(seconds: 3),
      );
      async.elapse(const Duration(seconds: 3));
      expect(controller.hasListener, isFalse);
    });
  });
}
