import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/capabilities.dart';
import 'package:player/core/sources/media_source.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/source_http.dart';
import 'package:player/core/sources/stash/stash_client.dart';
import 'package:player/core/sources/stash/stash_mapping.dart';
import 'package:player/core/sources/stash/stash_media_source.dart';
import 'package:player/core/sources/store/source_records.dart';
import 'package:player/domain/models/download_plan.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/domain/sources/library.dart';
import 'package:player/domain/sources/playback_sequence.dart';
import 'package:player/domain/sources/source_error.dart';

import '../fixed_connection.dart';
import '../media_source_contract.dart';
import 'fake_stash_server.dart';

final stashRecord = SourceAccountRecord(
  account: const ProviderAccount(
    id: 'st1',
    kind: SourceKind.stash,
    displayName: 'Shelf',
    storageNamespace: 'source/st1',
    activeProfileId: 'owner',
  ),
  profiles: const [
    SourceProfile(id: 'owner', accountId: 'st1', name: 'Owner', isOwner: true),
  ],
  servers: [
    SourceServer(
      id: 'main',
      accountId: 'st1',
      profileId: 'owner',
      name: 'Shelf',
      connections: [ServerConnection(uri: FakeStashServer.base, local: true)],
    ),
  ],
  addedAtMs: 0,
);

({StashMediaSource source, FakeStashServer server, List<int> unauthorized})
build({int? seed, List<int>? sceneIds}) {
  final server = FakeStashServer();
  if (sceneIds != null) server.sceneIds = sceneIds;
  final unauthorized = <int>[];
  final source = StashMediaSource(
    source: stashRecord.sources.single,
    client: StashClient(
      connection: FixedConnection(FakeStashServer.base),
      http: SourceHttp(client: server.client),
      apiKey: () async => FakeStashServer.apiKey,
      onUnauthorized: () => unauthorized.add(1),
    ),
    seed: seed,
  );
  return (source: source, server: server, unauthorized: unauthorized);
}

void main() {
  const sid = SourceId('st1:owner:main');

  runMediaSourceContract(
    'Stash',
    () async => ContractFixture(
      source: build().source,
      library: const LibraryRef(sourceId: sid, id: stashScenesLibraryId),
      playable: const ItemRef(
        sourceId: sid,
        kind: ItemKind.video,
        externalId: '2',
      ),
      libraryItemCount: 5,
    ),
  );

  test('strips the API key from server-made URLs', () {
    expect(
      stashRelativePath(
        'http://192.168.1.20:9999/scene/4/screenshot?t=1700&apikey=k',
      ),
      '/scene/4/screenshot?t=1700',
    );
    expect(stashRelativePath(null), isNull);
  });

  test('pages by page number with Stash sort names', () async {
    final b = build();
    await b.source.browse(
      const LibraryRef(sourceId: sid, id: stashScenesLibraryId),
      const BrowseQuery(sortId: 'date', filterIds: {'unplayed'}, pageSize: 2),
      cursor: const Cursor('2'),
    );
    final (name, vars) = b.server.operations.last;
    expect(name, 'FindScenes');
    expect(vars['filter'], {
      'page': 2,
      'per_page': 2,
      'sort': 'date',
      'direction': 'DESC',
    });
    expect(vars['scene_filter'], {
      'play_count': {'value': 0, 'modifier': 'EQUALS'},
    });
  });

  test('falls back to the file name for an untitled scene', () async {
    final page = await build().source.browse(
      const LibraryRef(sourceId: sid, id: stashScenesLibraryId),
      const BrowseQuery(),
    );
    expect(page.items[2].title, 'tidepool_3.mp4');
  });

  test('maps a scene with its file, captions and people', () async {
    final detail = await build().source.item(
      const ItemRef(sourceId: sid, kind: ItemKind.video, externalId: '2'),
    );
    expect(detail.summary.userState.watched, isTrue);
    expect(detail.summary.userState.progressSeconds, 300);
    expect(detail.studio, 'Kelpline');
    expect(detail.people, ['Oona Marsh']);
    expect(detail.rating, 8.0);
    final version = detail.versions.single;
    expect(version.id, '92');
    expect(version.height, 1080);
    expect(version.bitrateKbps, 6000);
    expect(version.streamPath, '/scene/2/stream');
    expect(
      version.streams.single.externalPath,
      '/scene/2/caption?lang=en&type=srt',
    );
  });

  test('resolves the original file with the API key in a header', () async {
    final plan = await build().source.resolve(
      const ItemRef(sourceId: sid, kind: ItemKind.video, externalId: '2'),
      'original',
    ) as DirectFile;
    expect(Uri.parse(plan.url).path, '/scene/2/stream');
    expect(plan.headers['ApiKey'], FakeStashServer.apiKey);
    expect(plan.url, isNot(contains(FakeStashServer.apiKey)));
  });

  test('a scene carries added and last played, no sort title', () async {
    final b = build();
    final detail = await b.source.item(
      ItemRef(sourceId: b.source.id, kind: ItemKind.video, externalId: '2'),
    );
    expect(detail.summary.addedAt, DateTime.utc(2024, 2, 2, 10));
    expect(detail.summary.lastPlayedAt, DateTime.utc(2024, 6, 2, 20));
    expect(detail.summary.sortTitle, isNull);
  });

  test(
    'recently added sorts by created_at, newest first, 20 at most',
    () async {
      final b = build();
      final items = await b.source.recentlyAdded();
      expect(items.first.ref.externalId, '5');
      final filter =
          b.server.operations
                  .lastWhere((o) => o.$1 == 'FindScenes')
                  .$2['filter']
              as Map;
      expect(filter['sort'], 'created_at');
      expect(filter['direction'], 'DESC');
      expect(filter['per_page'], 20);
    },
  );

  test('sort options tag title, added and released', () {
    final shared = {for (final o in stashSortOptions) o.id: o.shared};
    expect(shared['title'], SharedSort.title);
    expect(shared['created_at'], SharedSort.added);
    expect(shared['date'], SharedSort.released);
    expect(
      shared.entries.where((e) => e.value != null).map((e) => e.key),
      unorderedEquals(['title', 'created_at', 'date']),
    );
  });

  test('watched writes add a play or reset the count', () async {
    final b = build();
    const ref = ItemRef(sourceId: sid, kind: ItemKind.video, externalId: '2');
    await b.source.as<WatchedState>()!.setWatched(ref, true);
    expect(b.server.operations.last.$1, 'AddPlay');
    await b.source.as<WatchedState>()!.setWatched(ref, false);
    expect(b.server.operations.last.$1, 'ResetPlayCount');
  });

  test(
    'pushProgress throws when the answer carries no mutation result',
    () async {
      final b = build();
      const ref = ItemRef(sourceId: sid, kind: ItemKind.video, externalId: '2');
      final sync = b.source.as<ProgressSync>()!;
      await sync.pushProgress(
        ref,
        positionSeconds: 30,
        durationSeconds: 100,
        watched: true,
      );

      b.server.emptyMutationAnswers = true;
      await expectLater(
        sync.pushProgress(
          ref,
          positionSeconds: 30,
          durationSeconds: 100,
          watched: false,
        ),
        throwsA(isA<SourceException>()),
      );
    },
  );

  test('a false sceneSaveActivity is not a confirmed save', () async {
    final b = build();
    const ref = ItemRef(sourceId: sid, kind: ItemKind.video, externalId: '2');
    final sync = b.source.as<ProgressSync>()!;
    b.server.saveActivityAnswer = false;
    await expectLater(
      sync.pushProgress(
        ref,
        positionSeconds: 30,
        durationSeconds: 100,
        watched: false,
      ),
      throwsA(isA<SourceException>()),
    );
  });

  test('a schema without a field is unsupported, not a crash', () async {
    final b = build();
    b.server.graphqlError =
        'Cannot query field "sceneAddPlay" on type "Mutation".';
    await expectLater(
      b.source.as<WatchedState>()!.setWatched(
        const ItemRef(sourceId: sid, kind: ItemKind.video, externalId: '2'),
        true,
      ),
      throwsA(
        isA<SourceException>().having(
          (e) => e.kind,
          'kind',
          SourceErrorKind.unsupported,
        ),
      ),
    );
  });

  test('a rejected key reports unauthorized', () async {
    final b = build();
    b.server.status = 401;
    await expectLater(
      b.source.libraries(),
      completes,
      reason: 'the synthetic library needs no request',
    );
    await expectLater(
      b.source.browse(
        const LibraryRef(sourceId: sid, id: stashScenesLibraryId),
        const BrowseQuery(),
      ),
      throwsA(isA<SourceException>()),
    );
    expect(b.unauthorized, [1]);
  });

  test('artwork resolves against the base with the key in a header', () async {
    final request = await build().source.artwork(
      const ArtworkRef('/scene/4/screenshot?t=1700'),
      width: 300,
    );
    expect(request!.url, 'http://192.168.1.20:9999/scene/4/screenshot?t=1700');
    expect(request.headers['ApiKey'], FakeStashServer.apiKey);
  });

  test('checkStatus passes on OK', () async {
    await build().source.client.checkStatus();
  });

  test('declares Continue Watching', () {
    final source = build().source;
    expect(source.capabilities, contains(SourceCapability.continueWatching));
    expect(source.capabilities, isNot(contains(SourceCapability.trending)));
  });

  test(
    'Continue Watching asks for resumable scenes, last played first',
    () async {
      final b = build();
      final items = await b.source.continueWatching();
      final (name, vars) = b.server.operations.last;
      expect(name, 'FindScenes');
      expect(vars['filter'], {
        'page': 1,
        'per_page': 20,
        'sort': 'last_played_at',
        'direction': 'DESC',
      });
      expect(vars['scene_filter'], {
        'resume_time': {'value': 0, 'modifier': 'GREATER_THAN'},
      });
      expect(items.map((i) => i.ref.externalId), ['4', '2']);
      expect(items.first.userState.progressSeconds, 120);
    },
  );

  test('remove clears the resume point', () async {
    final b = build();
    await b.source.removeFromContinueWatching(
      const ItemRef(sourceId: sid, kind: ItemKind.video, externalId: '2'),
    );
    final (name, vars) = b.server.operations.last;
    expect(name, 'SaveActivity');
    expect(vars, {'id': '2', 'resume_time': 0});
  });

  test('every Continue Watching entry can be removed', () async {
    final source = build().source;
    final items = await source.continueWatching();
    expect(items, isNotEmpty);
    expect(items.every(source.canRemoveFromContinueWatching), isTrue);
  });

  group('SceneSequence', () {
    ItemRef ref(int n) =>
        ItemRef(sourceId: sid, kind: ItemKind.video, externalId: '$n');
    PlaybackSequence lib(int position, {String? sortId, bool? descending}) =>
        PlaybackSequence(
          origin: SequenceOrigin.library,
          position: position,
          // The fake reverses `created_at DESC`; title keeps ids ascending.
          sortId: sortId ?? 'title',
          descending: descending,
        );
    List<int> ids(int count) => [for (var n = 1; n <= count; n++) n];
    String id(SequenceNeighbour? n) => n!.item.ref.externalId;

    test('is a capability of the Stash source', () {
      expect(build().source.as<SceneSequence>(), isNotNull);
    });

    test('middle of library', () async {
      final b = build();
      final r = await b.source.as<SceneSequence>()!.neighbours(ref(3), lib(2));
      expect(id(r.previous), '2');
      expect(r.previous!.position, 1);
      expect(id(r.next), '4');
      expect(r.next!.position, 3);
      expect(r.next!.item.defaultVersionId, '94');
    });

    test('first and last', () async {
      final seq = build().source.as<SceneSequence>()!;
      final first = await seq.neighbours(ref(1), lib(0));
      expect(first.previous, isNull);
      expect(id(first.next), '2');
      final last = await seq.neighbours(ref(5), lib(4));
      expect(id(last.previous), '4');
      expect(last.next, isNull);
    });

    test('crosses a page boundary', () async {
      final b = build(sceneIds: ids(70));
      final r = await b.source.as<SceneSequence>()!.neighbours(
        ref(60),
        lib(59),
      );
      expect(id(r.previous), '59');
      expect(id(r.next), '61');
      expect(r.next!.position, 60);
      final pages = [
        for (final (name, vars) in b.server.operations)
          if (name == 'FindScenes') (vars['filter'] as Map)['page'],
      ];
      expect(pages, [1, 2]);
    });

    test('list shifted by one', () async {
      final b = build(sceneIds: [1, 2, 9, 3, 4, 5]);
      final r = await b.source.as<SceneSequence>()!.neighbours(ref(3), lib(2));
      expect(id(r.previous), '9');
      expect(r.previous!.position, 2);
      expect(id(r.next), '4');
      expect(r.next!.position, 4);
    });

    test('scene gone', () async {
      final b = build();
      final r = await b.source.as<SceneSequence>()!.neighbours(ref(42), lib(2));
      expect(id(r.previous), '2');
      expect(r.previous!.position, 1);
      expect(id(r.next), '3');
      expect(r.next!.position, 2);
    });

    test('search origin sends q and per_page 40', () async {
      final b = build();
      final r = await b.source.as<SceneSequence>()!.neighbours(
        ref(2),
        const PlaybackSequence(
          origin: SequenceOrigin.search,
          position: 1,
          query: 'Tidepool',
        ),
      );
      final (_, vars) = b.server.operations.last;
      expect((vars['filter'] as Map)['q'], 'Tidepool');
      expect((vars['filter'] as Map)['per_page'], 40);
      // Scene 3 has no title, so the fake's search skips it.
      expect(id(r.next), '4');
      expect(r.next!.position, 2);
    });

    test('continueWatching origin sends the resume_time filter', () async {
      final b = build();
      final r = await b.source.as<SceneSequence>()!.neighbours(
        ref(4),
        const PlaybackSequence(
          origin: SequenceOrigin.continueWatching,
          position: 0,
        ),
      );
      final (_, vars) = b.server.operations.last;
      expect(vars['scene_filter'], {
        'resume_time': {'value': 0, 'modifier': 'GREATER_THAN'},
      });
      expect(r.previous, isNull);
      expect(id(r.next), '2');
    });

    test('graphql error returns none', () async {
      final b = build();
      b.server.graphqlError = 'boom';
      final r = await b.source.as<SceneSequence>()!.neighbours(ref(3), lib(2));
      expect(r, same(SequenceNeighbours.none));
    });

    test('random sort is seeded', () async {
      final b = build(seed: 42);
      const library = LibraryRef(sourceId: sid, id: stashScenesLibraryId);
      const query = BrowseQuery(sortId: 'random', pageSize: 2);
      await b.source.browse(library, query);
      await b.source.browse(library, query, cursor: const Cursor('2'));
      final sorts = [
        for (final (name, vars) in b.server.operations)
          if (name == 'FindScenes') (vars['filter'] as Map)['sort'],
      ];
      expect(sorts, ['random_42', 'random_42']);
    });

    test('random neighbours use the same seed', () async {
      final b = build(seed: 42);
      await b.source.as<SceneSequence>()!.neighbours(
        ref(3),
        lib(2, sortId: 'random'),
      );
      final (_, vars) = b.server.operations.last;
      expect((vars['filter'] as Map)['sort'], 'random_42');
    });

    test('stashSummary sets defaultVersionId', () {
      final summary = stashSummary(sid, FakeStashServer.scene(2));
      expect(summary.defaultVersionId, '92');
    });
  });
}
