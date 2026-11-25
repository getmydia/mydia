/// Home's single-library preview rows and Continue Watching carry the scene
/// list into the item and player locations, for a source that can name a
/// scene's neighbours.
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/capabilities.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/domain/sources/playback_sequence.dart';
import 'package:player/presentation/screens/home/home_scope.dart';

import '../../../domain/merged/fake_merged_source.dart';
import 'home_screen_test.dart' show cardKey, pumpHome;

class _SceneServer extends FakeMergedSource implements SceneSequence {
  _SceneServer(super.source, {super.movies, super.resuming});

  @override
  Future<SequenceNeighbours> neighbours(
    ItemRef ref,
    PlaybackSequence sequence,
  ) async => SequenceNeighbours.none;
}

FakeMergedSource _server({required bool scenes}) {
  final s = fakeServer('a');
  final movies = [
    for (var n = 1; n <= 4; n++) item(s, 'v$n', kind: ItemKind.video),
  ];
  final resuming = [
    item(s, 'r1', kind: ItemKind.video, progress: 60, durationSeconds: 600),
    item(s, 'r2', kind: ItemKind.video, progress: 60, durationSeconds: 600),
  ];
  return scenes
      ? _SceneServer(s, movies: movies, resuming: resuming)
      : FakeMergedSource(s, movies: movies, resuming: resuming);
}

Finder _libraryPoster(FakeMergedSource s, String id) => find.descendant(
  of: find.byKey(ValueKey('home-library-${s.id.value}-movies')),
  matching: find.byKey(ValueKey('source-poster-$id')),
);

void main() {
  testWidgets('a library preview scene opens with its recently-added place', (
    t,
  ) async {
    final a = _server(scenes: true);
    final pushed = await pumpHome(t, [a], scope: OneServer(a.id));
    await t.tap(_libraryPoster(a, 'v2'));
    await t.pumpAndSettle();
    final opened = Uri.parse(pushed.last);
    expect(opened.path, endsWith('/item/video/v2'));
    expect(opened.queryParameters, {
      'seq': 'library',
      'seqPos': '1',
      'seqSort': 'added',
    });
  });

  testWidgets('a library preview from a plain source opens as today', (
    t,
  ) async {
    final a = _server(scenes: false);
    final pushed = await pumpHome(t, [a], scope: OneServer(a.id));
    await t.tap(_libraryPoster(a, 'v2'));
    await t.pumpAndSettle();
    expect(Uri.parse(pushed.last).queryParameters, isEmpty);
  });

  testWidgets('a Continue Watching scene plays with its place', (t) async {
    final a = _server(scenes: true);
    final pushed = await pumpHome(t, [a], scope: OneServer(a.id));
    await t.tap(find.byKey(cardKey(a, 'r2')));
    await t.pumpAndSettle();
    final opened = Uri.parse(pushed.last);
    expect(opened.path, endsWith('/player/r2'));
    expect(opened.queryParameters['seq'], 'continueWatching');
    expect(opened.queryParameters['seqPos'], '1');
  });

  testWidgets('a Continue Watching scene from a plain source plays as today', (
    t,
  ) async {
    final a = _server(scenes: false);
    final pushed = await pumpHome(t, [a], scope: OneServer(a.id));
    await t.tap(find.byKey(cardKey(a, 'r2')));
    await t.pumpAndSettle();
    expect(Uri.parse(pushed.last).queryParameters.keys, isNot(contains('seq')));
  });
}
