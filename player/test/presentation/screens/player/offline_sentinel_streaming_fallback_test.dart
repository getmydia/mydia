// Regression coverage for the `'offline'` file-id sentinel reaching the
// streaming candidates query.
//
// `downloads_screen.dart` and `series_downloads_screen.dart` both navigate to
// `PlayerScreen` with `fileId: 'offline'` for anything already downloaded —
// there is no real file id to thread through, because the point of that route
// is "play what's on disk". When the stored local path has rotted (OS
// cleanup, a container path change across an app update),
// `_resolveDownloadedFilePath` returns null and the "already downloaded,
// still online" branch falls through to network streaming without ever
// returning — carrying `widget.fileId` still literally `'offline'` into the
// code that used to fetch streaming candidates keyed on the file.
//
// A `binary_id` GraphQL argument can't parse `'offline'`, so before this
// file's fix a live server would raise `Ecto.Query.CastError` and playback
// would fail outright. `PlayerScreen` has to recognize the sentinel and fall
// back to asking about the *media item* instead, the same way it did before
// the file-keyed candidates query existed.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/connection/connection_provider.dart' as conn;

import '../../../test_utils/stub_graphql_client.dart';
import 'player_screen_test_harness.dart';

void main() {
  setUp(mockPathProviderDocumentsDirectory);

  testWidgets(
      'a downloaded file missing from disk still reaches a real stream, '
      'not the offline sentinel', (tester) async {
    // A path that was never written: `_resolveDownloadedFilePath` fails its
    // first check (`file_utils.fileExists`) and, with `path_provider` mocked
    // to a temp dir that shares no files with this one, every fallback it
    // tries misses too — reproducing a download whose backing file rotted
    // out from under a stale record.
    final tempDir = Directory.systemTemp
        .createTempSync('mydia_offline_sentinel_fallback_test_');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final missingPath = '${tempDir.path}/arrival.mkv';

    final proxyService = TrackingLocalProxyService();

    // `streamingCandidatesResponse` hardcodes fileId 'file-1' — the id the
    // server ranked highest for the movie. Direct play must end up streaming
    // that id, never the literal string 'offline'.
    final link = StubLink.responses([
      movieDetailResponse(),
      movieSegmentsResponse(),
      streamingCandidatesResponse(duration: 5400, directPlay: true),
    ]);

    final container = buildPlayerScreenContainer(
      link: link,
      // P2P so the direct-play URL is built by the tracked proxy, not the
      // real media-token service — same choice as
      // player_honors_selected_file_test.dart, for the same reason.
      connectionState: conn.ConnectionState.p2p(serverNodeAddr: 'node-addr'),
      castManager: CapturingCastSessionManager(),
      proxyService: proxyService,
      // Online mode (default authStatus), but with a download on record: the
      // "already downloaded, still online" branch, not the offline-mode one.
      downloaded: downloadedItem(filePath: missingPath, runtimeMinutes: 90),
    );
    addTearDown(container.dispose);

    // `_resolveDownloadedFilePath`'s fallbacks do real `dart:io` and
    // `path_provider` I/O (see offline_resume_test.dart's doc comments for
    // why plain `pump()` can't observe that), so this has to run inside
    // `runAsync` and poll for the real outcome rather than pump a fixed
    // number of times.
    await tester.runAsync(() async {
      await pumpPlayerScreen(tester, container, fileId: 'offline');
      await pumpUntilReal(
        tester,
        () => proxyService.capturedDirectStreamFileId != null,
      );
    });

    expect(
      proxyService.capturedDirectStreamFileId,
      'file-1',
      reason: 'the offline sentinel must never reach the direct-play URL — '
          'once streaming takes over it has to play whatever the server '
          'ranked for the media item',
    );

    // Third scripted call, matching the response order above: detail,
    // segments, candidates. `StubLink` is index-based, so this ordering is
    // the same one every other PlayerScreen test relies on.
    final candidatesVariables = link.requests[2].variables;
    expect(
      candidatesVariables['contentType'],
      'movie',
      reason: 'there is no file to ask about once the sentinel is in play, '
          'so the fallback has to ask by media item instead',
    );
    expect(candidatesVariables['id'], 'movie-1');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
