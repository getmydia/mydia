// A downloaded file plays from any source. The session says which source the
// item belongs to and whether its server is reachable; the screen looks the
// download up under that source and keys local progress by it, so a
// third-party id never finds (or resumes from) a home record that shares it.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/playback/local_playback_progress.dart';
import 'package:player/core/playback/playback_progress_store.dart';
import 'package:player/core/sources/source.dart' show SourceId;
import 'package:player/domain/models/download.dart';
import 'package:player/domain/sources/item.dart';

import '../../../test_utils/scripted_mydia_transport.dart';
import 'player_screen_test_harness.dart';
import 'session/fake_playback_session.dart';
import '../../../test_utils/mydia_test_source.dart';

const _thirdParty = SourceId('acc1:owner:aa11');
const _item = ItemRef(
  sourceId: _thirdParty,
  kind: ItemKind.movie,
  externalId: '42',
);

/// Answers by the item asked for, like the real service does.
class _KeyedDownloadService extends FakeDownloadService {
  _KeyedDownloadService(this.byItem);

  final Map<ItemRef, DownloadedMedia> byItem;
  final asked = <ItemRef>[];

  @override
  DownloadedMedia? getDownloaded(ItemRef ref) {
    asked.add(ref);
    return byItem[ref];
  }
}

DownloadedMedia _record({
  required String filePath,
  String? sourceId,
}) =>
    DownloadedMedia(
      id: 'dl-${sourceId ?? 'none'}',
      mediaId: '42',
      sourceId: sourceId,
      title: 'Quill Harbor',
      quality: 'original',
      filePath: filePath,
      fileSize: 1,
      mediaType: 'movie',
      downloadedAt: DateTime(2026, 1, 1),
      runtime: 90,
    );

void main() {
  setUp(mockPathProviderDocumentsDirectory);

  Future<void> run(
    WidgetTester tester, {
    PlaybackProgressStore? store,
    LocalPlaybackProgress? seeded,
    required void Function(_KeyedDownloadService service) onReady,
    required Future<void> Function() body,
  }) async {
    final tempDir =
        Directory.systemTemp.createTempSync('mydia_source_download_test_');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final thirdPartyFile = File('${tempDir.path}/third-party.mkv')
      ..writeAsBytesSync(const [0]);
    // The home record points at a file that does not exist, so choosing it
    // would show "Downloaded file not found" instead of reaching the player.
    final homeFile = '${tempDir.path}/mydia-missing.mkv';

    final service = _KeyedDownloadService({
      _item:
          _record(filePath: thirdPartyFile.path, sourceId: _thirdParty.value),
      const ItemRef(
        sourceId: testMydiaSourceId,
        kind: ItemKind.movie,
        externalId: '42',
      ): _record(filePath: homeFile, sourceId: testMydiaSourceId.value),
    });
    onReady(service);

    final progressStore = store ?? InMemoryPlaybackProgressStore();
    final container = buildPlayerScreenContainer(
      server: ScriptedMydiaTransport((request, callIndex) =>
          throw StateError('an unreachable source must not issue GraphQL')),
      connectionState: HarnessLink.direct(),
      castManager: CapturingCastSessionManager(),
      proxyService: TrackingLocalProxyService(),
      downloadService: service,
      progressStore: progressStore,
    );
    addTearDown(container.dispose);
    if (seeded != null) await progressStore.save(seeded);

    await tester.runAsync(() async {
      await pumpPlayerScreen(
        tester,
        container,
        mediaId: '42',
        session: FakePlaybackSession(item: _item, reachable: false),
      );
      await body();
    });
  }

  testWidgets('an unreachable source plays its own record, from the start',
      (tester) async {
    late _KeyedDownloadService service;
    await run(
      tester,
      onReady: (s) => service = s,
      body: () => pumpUntilReal(
        tester,
        () => find.byType(CircularProgressIndicator).evaluate().isEmpty,
      ),
    );

    expect(service.asked, contains(_item));
    expect(find.textContaining('Downloaded file not found'), findsNothing,
        reason: 'the home record has the same id but is not this item');
    // The third-party file exists, so the load got as far as building the
    // media_kit player, which `flutter test` cannot.
    expect(find.textContaining('MediaKit.ensureInitialized'), findsOneWidget);
    expect(find.text('Resume'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('resumes from the position kept under the source key',
      (tester) async {
    await run(
      tester,
      seeded: LocalPlaybackProgress(
        sourceId: _thirdParty.value,
        mediaId: '42',
        mediaType: 'movie',
        positionSeconds: 2700,
        durationSeconds: 5400,
        updatedAt: DateTime.utc(2026, 8, 2, 12),
      ),
      onReady: (_) {},
      body: () => pumpUntilReal(
        tester,
        () => find.text('Resume').evaluate().isNotEmpty,
      ),
    );

    expect(find.text('Resume'), findsOneWidget);
    expect(progressKey(_item), 'acc1:owner:aa11|42');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets(
      'a position kept for another source with the same id is not resumed from',
      (tester) async {
    await run(
      tester,
      seeded: LocalPlaybackProgress(
        sourceId: testMydiaSourceId.value,
        mediaId: '42',
        mediaType: 'movie',
        positionSeconds: 2700,
        durationSeconds: 5400,
        updatedAt: DateTime.utc(2026, 8, 2, 12),
      ),
      onReady: (_) {},
      body: () => pumpUntilReal(
        tester,
        () => find.byType(CircularProgressIndicator).evaluate().isEmpty,
      ),
    );

    expect(find.text('Resume'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
