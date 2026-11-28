import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:player/presentation/screens/player/player_screen.dart';
import 'package:player/presentation/widgets/hero_play_control.dart';
import 'package:player/presentation/widgets/primary_play_button.dart';

import 'helpers/e2e_api_client.dart';
import 'helpers/login_helpers.dart';
import 'helpers/playback_rig.dart' show pumpBounded;
import 'helpers/streaming_helpers.dart';
import 'helpers/test_bootstrap.dart';

/// Why a test fails when the server has no file for the seeded movie.
const _noSeededFile =
    'No media file for E2E Test Movie: scripts/e2e/seed.sh seeds it, so '
    'the server or the seed is broken';

/// Pumps frames until [condition] holds, and fails naming [what] once
/// [timeout] passes without it.
Future<void> _pumpUntil(
  WidgetTester tester,
  String what,
  FutureOr<bool> Function() condition, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out after $timeout waiting for $what');
    }
    await pumpBounded(
      tester,
      'a frame while waiting for $what',
      () => tester.pump(const Duration(milliseconds: 250)),
    );
  }
}

/// E2E integration tests for P2P streaming functionality.
///
/// These tests verify that HLS streaming works correctly over the iroh-based
/// P2P connection. They test both the direct HTTP streaming path and the
/// P2P proxy path.
///
/// Prerequisites:
/// - Mydia server with test media (auto-generated in E2E setup)
/// - Metadata relay service running
/// - Device paired with server
///
/// Test scenarios:
/// 1. Direct HTTP streaming works (HLS path)
/// 2. P2P connection can be established
/// 3. Streaming over P2P works end-to-end (HLS)
/// 4. Streaming candidates query returns valid candidates
/// 5. Direct file streaming works via HTTP (direct play path)
/// 6. Playback can start via the player UI
void main() {
  // Initialize integration test binding FIRST
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final apiClient = E2eApiClient.fromEnvironment();

  // Set up the app once before all tests
  setUpAll(() async {
    await ensureTestBootstrap();

    await apiClient.waitForHealthy();
    await apiClient.login();
  });

  Future<String> generateFreshClaimCode() async {
    const maxAttempts = 10;

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final claim = await apiClient.generateClaimCode();
        debugPrint(
          '[P2P Streaming Test] Generated fresh claim code: ${claim.code}',
        );
        return claim.code;
      } catch (error) {
        if (attempt == maxAttempts) {
          rethrow;
        }

        debugPrint(
          '[P2P Streaming Test] Claim code generation attempt $attempt failed: $error',
        );
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }

    throw StateError('Unable to generate a claim code');
  }

  /// Wait for pairing to complete and home screen to appear
  Future<bool> waitForPairingComplete(
    WidgetTester tester, {
    int maxSeconds = 120,
  }) async {
    debugPrint('[P2P Streaming Test] Waiting for pairing to complete...');
    for (var i = 0; i < maxSeconds; i++) {
      await tester.pump(const Duration(seconds: 1));
      await dismissStorageWarningIfShown(tester, tag: '[P2P Streaming Test]');
      final loginTitle = find.text('Connect to Server');
      if (loginTitle.evaluate().isEmpty) {
        debugPrint('[P2P Streaming Test] Paired successfully after $i seconds');
        return true;
      }
    }
    return false;
  }

  /// Perform device pairing
  Future<void> performPairing(WidgetTester tester) async {
    final landing = await waitForLoginOrSignedIn(
      tester,
      maxSeconds: 15,
      tag: '[P2P Streaming Test]',
    );
    if (landing == AppLanding.signedIn) {
      debugPrint(
        '[P2P Streaming Test] A Mydia account is already stored, skipping pairing',
      );
      return;
    }

    final claimCode = await generateFreshClaimCode();
    debugPrint('[P2P Streaming Test] Using claim code: $claimCode');

    // Enter claim code
    final textField = find.byType(TextFormField).first;
    expect(textField, findsOneWidget);
    await tester.enterText(textField, claimCode.replaceAll('-', ''));
    await tester.pump(const Duration(milliseconds: 300));

    // Tap Connect button
    final connectButton = find.widgetWithText(ElevatedButton, 'Connect');
    expect(connectButton, findsOneWidget);
    await tester.tap(connectButton);
    await tester.pump(const Duration(milliseconds: 100));

    // Wait for pairing
    final success = await waitForPairingComplete(tester);
    expect(success, isTrue, reason: 'Device pairing failed');
  }

  group('P2P Streaming E2E', () {
    testWidgets('Direct HTTP streaming works', (WidgetTester tester) async {
      debugPrint('[P2P Streaming Test] Starting direct HTTP streaming test');

      // Launch the app
      await tester.pumpWidget(testApp());

      // Complete pairing
      await performPairing(tester);

      // Get streaming helper
      final streaming = StreamingTestHelper.fromEnvironment();
      await streaming.initialize();

      // Get test media file ID
      final fileId = await streaming.getTestMediaFileId();
      if (fileId == null) fail(_noSeededFile);
      debugPrint('[P2P Streaming Test] Test media file ID: $fileId');

      // Start streaming session via GraphQL
      StreamingSession? session;

      try {
        session = await streaming.startStreamingSession();
        expect(session, isNotNull);
        expect(session!.hasHlsUrl, isTrue);
        debugPrint(
          '[P2P Streaming Test] Streaming session: ${session.sessionId}',
        );
        debugPrint('[P2P Streaming Test] HLS URL: ${session.hlsUrl}');

        // Wait for HLS playlist to be ready
        final playlistReady = await streaming.waitForHlsPlaylist(
          session.hlsUrl!,
          minSegments: 2,
          maxRetries: 30,
        );
        expect(
          playlistReady,
          isTrue,
          reason: 'HLS playlist should be ready with segments',
        );
        debugPrint('[P2P Streaming Test] HLS playlist is ready');

        // Verify segments are accessible
        final segmentsReady = await streaming.waitForSegmentData(
          session.hlsUrl!,
          maxRetries: 10,
        );
        expect(
          segmentsReady,
          isTrue,
          reason: 'HLS segments should be accessible',
        );
        debugPrint('[P2P Streaming Test] HLS segments are accessible');
      } finally {
        if (session != null) {
          await streaming.endStreamingSession(session.sessionId);
        }
      }

      // Stop app
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 100));

      debugPrint('[P2P Streaming Test] Direct HTTP streaming test passed!');
    });

    testWidgets('P2P connection can be established', (
      WidgetTester tester,
    ) async {
      debugPrint('[P2P Streaming Test] Starting P2P connection test');

      // Launch the app
      await tester.pumpWidget(testApp());

      // Complete pairing (this establishes P2P connection)
      await performPairing(tester);

      // Get streaming helper
      final streaming = StreamingTestHelper.fromEnvironment();
      await streaming.initialize();

      // Verify remote access status query works
      final status = await streaming.getP2pConnectionStatus();
      debugPrint('[P2P Streaming Test] P2P status: $status');
      expect(
        status.enabled,
        isTrue,
        reason: 'Remote access should be enabled in E2E mode',
      );

      // Wait for P2P connection
      final connected = await streaming.waitForP2pConnection(
        timeout: const Duration(seconds: 30),
      );
      debugPrint(
        '[P2P Streaming Test] waitForP2pConnection result: $connected',
      );

      // Stop app
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 100));

      debugPrint('[P2P Streaming Test] P2P connection test passed!');
    });

    testWidgets('P2P streaming works end-to-end', (WidgetTester tester) async {
      debugPrint('[P2P Streaming Test] Starting full P2P streaming test');

      // Launch the app
      await tester.pumpWidget(testApp());

      // Complete pairing
      await performPairing(tester);

      // Get streaming helper
      final streaming = StreamingTestHelper.fromEnvironment();
      await streaming.initialize();

      // Wait for P2P connection
      final p2pConnected = await streaming.waitForP2pConnection(
        timeout: const Duration(seconds: 30),
      );
      expect(
        p2pConnected,
        isTrue,
        reason: 'P2P connection must be established for P2P streaming',
      );

      // Get test media file ID
      final fileId = await streaming.getTestMediaFileId();
      expect(fileId, isNotNull);

      // Start streaming session
      final session = await streaming.startStreamingSession();
      expect(session, isNotNull);
      expect(session!.hasHlsUrl, isTrue);

      // Wait for HLS playlist via HTTP (to verify server-side works)
      final playlistReady = await streaming.waitForHlsPlaylist(
        session.hlsUrl!,
        minSegments: 2,
        maxRetries: 30,
      );
      expect(playlistReady, isTrue);

      // Verify segments work
      final segmentsReady = await streaming.waitForSegmentData(
        session.hlsUrl!,
        maxRetries: 10,
      );
      expect(segmentsReady, isTrue);

      // Clean up
      await streaming.endStreamingSession(session.sessionId);

      // Stop app
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 100));

      debugPrint('[P2P Streaming Test] P2P streaming test passed!');
    });

    testWidgets('Streaming candidates query returns valid candidates', (
      WidgetTester tester,
    ) async {
      debugPrint(
        '[P2P Streaming Test] Starting streaming candidates query test',
      );

      // Launch the app
      await tester.pumpWidget(testApp());

      // Complete pairing
      await performPairing(tester);

      // Get streaming helper
      final streaming = StreamingTestHelper.fromEnvironment();
      await streaming.initialize();

      // Get test media item ID
      final fileId = await streaming.getTestMediaFileId();
      if (fileId == null) fail(_noSeededFile);

      // We need the media item ID, not the file ID.
      // The getTestMediaFileId() also stores the item ID internally,
      // but we need to query again to get it.
      const query = r'''
        query GetTestMedia {
          movies(first: 50) {
            edges {
              node {
                id
                title
                files { id }
              }
            }
          }
        }
      ''';

      final response = await apiClient.graphqlRequest(query, {});
      final edges = response.object('data').object('movies').list('edges');
      String? mediaItemId;
      for (final edge in edges) {
        final movie = edge.object('node');
        final files = movie.field<Object?>('files') == null
            ? null
            : movie.list('files');
        if (files != null &&
            files.any((f) => f.field<Object?>('id') == fileId)) {
          mediaItemId = movie.field<String>('id');
          break;
        }
      }

      expect(
        mediaItemId,
        isNotNull,
        reason: 'Should find media item ID for test file',
      );

      // Fetch streaming candidates using the "movie" content type
      final candidates = await streaming.fetchStreamingCandidates(
        contentType: 'movie',
        id: mediaItemId!,
      );

      expect(
        candidates,
        isNotNull,
        reason: 'Streaming candidates should be returned',
      );
      debugPrint('[P2P Streaming Test] Candidates result: $candidates');

      // Verify we got candidates
      expect(
        candidates!.candidates,
        isNotEmpty,
        reason: 'Should have at least one streaming candidate',
      );

      // The E2E test video is H.264/AAC/MP4, which should be direct-playable
      expect(
        candidates.hasDirectPlay,
        isTrue,
        reason: 'H.264/AAC/MP4 test video should have DIRECT_PLAY candidate',
      );

      // Should also have a TRANSCODE fallback
      expect(
        candidates.hasTranscode,
        isTrue,
        reason: 'Should always have TRANSCODE fallback candidate',
      );

      // Verify file ID is returned
      expect(
        candidates.fileId,
        isNotEmpty,
        reason: 'Candidates should include fileId',
      );

      // Verify metadata
      expect(
        candidates.metadata,
        isNotNull,
        reason: 'Candidates should include metadata',
      );
      expect(
        candidates.metadata!.duration,
        isNotNull,
        reason: 'Metadata should include duration',
      );
      expect(
        candidates.metadata!.duration!,
        greaterThan(0),
        reason: 'Duration should be positive',
      );

      // Verify each candidate has required fields
      for (final candidate in candidates.candidates) {
        expect(
          candidate.strategy,
          isNotEmpty,
          reason: 'Candidate should have a strategy',
        );
        expect(
          candidate.mime,
          isNotEmpty,
          reason: 'Candidate should have a mime type',
        );
        expect(
          candidate.container,
          isNotEmpty,
          reason: 'Candidate should have a container',
        );
        debugPrint(
          '[P2P Streaming Test] Candidate: ${candidate.strategy} - ${candidate.mime}',
        );
      }

      // Also test with "file" content type
      final fileCandidates = await streaming.fetchStreamingCandidates(
        contentType: 'file',
        id: fileId,
      );
      expect(
        fileCandidates,
        isNotNull,
        reason: 'Should also work with "file" content type',
      );
      expect(
        fileCandidates!.candidates.length,
        candidates.candidates.length,
        reason: 'File and movie candidates should match',
      );

      // Stop app
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 100));

      debugPrint(
        '[P2P Streaming Test] Streaming candidates query test passed!',
      );
    });

    testWidgets('Direct file streaming works via HTTP', (
      WidgetTester tester,
    ) async {
      debugPrint('[P2P Streaming Test] Starting direct file streaming test');

      // Launch the app
      await tester.pumpWidget(testApp());

      // Complete pairing
      await performPairing(tester);

      // Get streaming helper
      final streaming = StreamingTestHelper.fromEnvironment();
      await streaming.initialize();

      // Get test media file ID
      final fileId = await streaming.getTestMediaFileId();
      if (fileId == null) fail(_noSeededFile);
      debugPrint('[P2P Streaming Test] Test media file ID: $fileId');

      // Verify direct file stream endpoint works (HTTP path)
      final directStreamOk = await streaming.verifyDirectFileStream(fileId);
      expect(
        directStreamOk,
        isTrue,
        reason: 'Direct file stream endpoint should return 200 or 206',
      );
      debugPrint(
        '[P2P Streaming Test] Direct file stream endpoint is accessible',
      );

      // Verify the full URL is also accessible via verifyUrlAccessible
      final directUrl = streaming.getDirectStreamUrl(fileId);
      final urlOk = await streaming.verifyUrlAccessible(directUrl);
      expect(urlOk, isTrue, reason: 'Direct stream URL should be accessible');
      debugPrint('[P2P Streaming Test] Direct stream URL verified: $directUrl');

      // Stop app
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 100));

      debugPrint('[P2P Streaming Test] Direct file streaming test passed!');
    });

    testWidgets('Player can navigate to video and start playback', (
      WidgetTester tester,
    ) async {
      debugPrint('[P2P Streaming Test] Starting player navigation test');

      // Launch the app
      await tester.pumpWidget(testApp());

      // Complete pairing
      await performPairing(tester);

      // The seeded movie, which the source home must list.
      final streaming = StreamingTestHelper.fromEnvironment();
      await streaming.initialize();
      final fileId = await streaming.getTestMediaFileId();
      if (fileId == null) fail(_noSeededFile);
      final movieId = streaming.testMediaItemId;
      if (movieId == null) fail('Found file $fileId but not its movie id');

      // The home list builds its rails lazily, so a rail below the hero
      // exists only once the list has scrolled to it.
      final homeList = find.byKey(const Key('home-list'));
      await _pumpUntil(
        tester,
        'the source home',
        () => homeList.evaluate().isNotEmpty,
        timeout: const Duration(seconds: 60),
      );
      final poster = find.byKey(ValueKey('source-poster-$movieId'));
      await _pumpUntil(tester, "E2E Test Movie's poster on the home", () async {
        if (poster.evaluate().isNotEmpty) return true;
        await tester.drag(homeList, const Offset(0, -300));
        return false;
      }, timeout: const Duration(seconds: 60));
      await tester.ensureVisible(poster.first);
      await pumpBounded(tester, 'a frame after scrolling to the poster', () {
        return tester.pump(const Duration(milliseconds: 100));
      });
      await tester.tap(poster.first);

      final playButton = find.descendant(
        of: find.byType(HeroPlayControl),
        matching: find.byType(PrimaryPlayButton),
      );
      // Play mounts disabled: SmartPlayButton picks its file asynchronously
      // and only then gives the button an onPressed. A tap before that does
      // nothing, so the player never opens; wait for the enabled button.
      await _pumpUntil(
        tester,
        "the movie page's enabled Play button",
        () =>
            playButton.evaluate().isNotEmpty &&
            tester.widget<PrimaryPlayButton>(playButton.first).onPressed !=
                null,
      );
      await tester.tap(playButton.first);

      final player = find.byType(PlayerScreen);
      await _pumpUntil(
        tester,
        'the player screen',
        () => player.evaluate().isNotEmpty,
      );
      debugPrint('[P2P Streaming Test] Player screen mounted');

      // Back to the movie page, which disposes the player.
      await Navigator.of(tester.element(player)).maybePop();
      await _pumpUntil(
        tester,
        'the movie page after leaving the player',
        () => player.evaluate().isEmpty && playButton.evaluate().isNotEmpty,
      );

      // Stop app
      await pumpBounded(
        tester,
        'a frame while unmounting the app',
        () => tester.pumpWidget(const SizedBox.shrink()),
      );
      await pumpBounded(tester, 'a frame after unmounting the app', () {
        return tester.pump(const Duration(milliseconds: 100));
      });

      debugPrint('[P2P Streaming Test] Player navigation test completed');
    });
  });
}
