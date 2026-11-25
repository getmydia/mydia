import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/capabilities.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/domain/sources/playback_sequence.dart';
import 'package:player/presentation/screens/sources/scene_sequence_links.dart';

import 'fake_media_source.dart';

/// A fake that, like Stash, can name the scenes either side of one.
class FakeSceneSource extends FakeMediaSource implements SceneSequence {
  FakeSceneSource({super.movieCount});

  @override
  Future<SequenceNeighbours> neighbours(
    ItemRef ref,
    PlaybackSequence sequence,
  ) async => SequenceNeighbours.none;
}

ItemSummary fakeScene(int n) => ItemSummary(
  ref: ItemRef(sourceId: fakeSourceId, kind: ItemKind.video, externalId: 'v$n'),
  title: 'Invented Scene $n',
);

void main() {
  const sequence = PlaybackSequence(
    origin: SequenceOrigin.library,
    position: 2,
    sortId: 'date',
  );

  test('a scene of a SceneSequence source gets the sequence', () {
    expect(
      sceneSequenceFor(FakeSceneSource(), fakeScene(3), () => sequence),
      sequence,
    );
  });

  test('a source without SceneSequence gets none', () {
    var built = false;
    expect(
      sceneSequenceFor(FakeMediaSource(), fakeScene(3), () {
        built = true;
        return sequence;
      }),
      isNull,
    );
    expect(built, isFalse);
  });

  test('a movie gets none, even from a SceneSequence source', () {
    expect(
      sceneSequenceFor(FakeSceneSource(), fakeMovie(3), () => sequence),
      isNull,
    );
  });

  test('no source gets none', () {
    expect(sceneSequenceFor(null, fakeScene(3), () => sequence), isNull);
  });
}
