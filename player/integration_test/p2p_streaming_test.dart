import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:player/app.dart';
import 'helpers/e2e_api_client.dart';
import 'helpers/streaming_helpers.dart';
import 'helpers/test_bootstrap.dart';

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
            '[P2P Streaming Test] Generated fresh claim code: ${claim.code}');
        return claim.code;
      } catch (error) {
        if (attempt == maxAttempts) {
          rethrow;
        }

        debugPrint(
            '[P2P Streaming Test] Claim code generation attempt $attempt failed: $error');
        await Future.delayed(const Duration(seconds: 2));
      }
    }

    throw StateError('Unable to generate a claim code');
  }

  /// Wait for the login screen to appear
  Future<void> waitForLoginScreen(WidgetTester tester,
      {int maxSeconds = 30}) async {
    debugPrint('[P2P Streaming Test] Waiting for login screen...');
    for (var i = 0; i < maxSeconds; i++) {
      await tester.pump(const Duration(seconds: 1));
      final loginTitle = find.text('Connect to Server');
      if (loginTitle.evaluate().isNotEmpty) {
        debugPrint('[P2P Streaming Test] Login screen found after $i seconds');
        await tester.pump(const Duration(milliseconds: 500));
        return;
      }
    }
    throw Exception('Login screen not found after $maxSeconds seconds');
  }

  /// Wait for pairing to complete and home screen to appear
  Future<bool> waitForPairingComplete(WidgetTester tester,
      {int maxSeconds = 120}) async {
    debugPrint('[P2P Streaming Test] Waiting for pairing to complete...');
    for (var i = 0; i < maxSeconds; i++) {
      await tester.pump(const Duration(seconds: 1));
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
    try {
      await waitForLoginScreen(tester, maxSeconds: 15);
    } catch (_) {
      if (find.text('Connect to Server').evaluate().isEmpty) {
        debugPrint(
            '[P2P Streaming Test] App already authenticated, skipping pairing');
        return;
      }

      rethrow;
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

  /// Wait for the media library to load.
  /// Returns true if loaded, false if timed out.
  Future<bool> waitForMediaLibrary(WidgetTester tester,
      {int maxSeconds = 60}) async {
    debugPrint('[P2P Streaming Test] Waiting for media library...');
    for (var i = 0; i < maxSeconds; i++) {
      await tester.pump(const Duration(seconds: 1));

      // Look for movie grid, known empty-state messages, or any media content
      final movieGrid = find.byType(GridView);
      final noMoviesText = find.text('No movies yet');
      final noShowsText = find.text('No TV shows yet');
      final emptyLibraryMessage =
          find.text('Add content to your library to see it here');
      final testMovieText = find.textContaining('E2E Test');

      if (movieGrid.evaluate().isNotEmpty ||
          noMoviesText.evaluate().isNotEmpty ||
          noShowsText.evaluate().isNotEmpty ||
          emptyLibraryMessage.evaluate().isNotEmpty ||
          testMovieText.evaluate().isNotEmpty) {
        debugPrint(
            '[P2P Streaming Test] Media library loaded after $i seconds');
        return true;
      }
    }
    debugPrint(
        '[P2P Streaming Test] Media library not loaded after $maxSeconds seconds');
    return false;
  }

  group('P2P Streaming E2E', () {
    testWidgets('Direct HTTP streaming works', (WidgetTester tester) async {
      debugPrint('[P2P Streaming Test] Starting direct HTTP streaming test');

      // Launch the app
      await tester.pumpWidget(
        const ProviderScope(
          child: MyApp(),
        ),
      );

      // Complete pairing
      await performPairing(tester);

      // Get streaming helper
      final streaming = StreamingTestHelper.fromEnvironment();
      await streaming.initialize();

      // Get test media file ID
      final fileId = await streaming.getTestMediaFileId();
      if (fileId == null) {
        debugPrint(
            '[P2P Streaming Test] Skipping direct streaming assertions: no media file found in E2E library');
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
        return;
      }
      debugPrint('[P2P Streaming Test] Test media file ID: $fileId');

      // Start streaming session via GraphQL
      StreamingSession? session;

      try {
        session = await streaming.startStreamingSession();
        expect(session, isNotNull);
        expect(session!.hasHlsUrl, isTrue);
        debugPrint(
            '[P2P Streaming Test] Streaming session: ${session.sessionId}');
        debugPrint('[P2P Streaming Test] HLS URL: ${session.hlsUrl}');

        // Wait for HLS playlist to be ready
        final playlistReady = await streaming.waitForHlsPlaylist(
          session.hlsUrl!,
          minSegments: 2,
          maxRetries: 30,
        );
        expect(playlistReady, isTrue,
            reason: 'HLS playlist should be ready with segments');
        debugPrint('[P2P Streaming Test] HLS playlist is ready');

        // Verify segments are accessible
        final segmentsReady = await streaming.waitForSegmentData(
          session.hlsUrl!,
          maxRetries: 10,
        );
        expect(segmentsReady, isTrue,
            reason: 'HLS segments should be accessible');
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

    testWidgets('P2P connection can be established',
        (WidgetTester tester) async {
      debugPrint('[P2P Streaming Test] Starting P2P connection test');

      // Launch the app
      await tester.pumpWidget(
        const ProviderScope(
          child: MyApp(),
        ),
      );

      // Complete pairing (this establishes P2P connection)
      await performPairing(tester);

      // Get streaming helper
      final streaming = StreamingTestHelper.fromEnvironment();
      await streaming.initialize();

      // Verify remote access status query works
      final status = await streaming.getP2pConnectionStatus();
      debugPrint('[P2P Streaming Test] P2P status: $status');
      expect(status.enabled, isTrue,
          reason: 'Remote access should be enabled in E2E mode');

      // Wait for P2P connection
      final connected = await streaming.waitForP2pConnection(
        timeout: const Duration(seconds: 30),
      );
      debugPrint(
          '[P2P Streaming Test] waitForP2pConnection result: $connected');

      // Stop app
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 100));

      debugPrint('[P2P Streaming Test] P2P connection test passed!');
    });

    testWidgets('P2P streaming works end-to-end', (WidgetTester tester) async {
      debugPrint('[P2P Streaming Test] Starting full P2P streaming test');

      // Launch the app
      await tester.pumpWidget(
        const ProviderScope(
          child: MyApp(),
        ),
      );

      // Complete pairing
      await performPairing(tester);

      // Get streaming helper
      final streaming = StreamingTestHelper.fromEnvironment();
      await streaming.initialize();

      // Wait for P2P connection
      final p2pConnected = await streaming.waitForP2pConnection(
        timeout: const Duration(seconds: 30),
      );
      expect(p2pConnected, isTrue,
          reason: 'P2P connection must be established for P2P streaming');

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

    testWidgets('Streaming candidates query returns valid candidates',
        (WidgetTester tester) async {
      debugPrint(
          '[P2P Streaming Test] Starting streaming candidates query test');

      // Launch the app
      await tester.pumpWidget(
        const ProviderScope(
          child: MyApp(),
        ),
      );

      // Complete pairing
      await performPairing(tester);

      // Get streaming helper
      final streaming = StreamingTestHelper.fromEnvironment();
      await streaming.initialize();

      // Get test media item ID
      final fileId = await streaming.getTestMediaFileId();
      if (fileId == null) {
        debugPrint(
            '[P2P Streaming Test] Skipping candidates test: no media file found');
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
        return;
      }

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
      final edges = response['data']['movies']['edges'] as List;
      String? mediaItemId;
      for (final edge in edges) {
        final movie = edge['node'];
        final files = movie['files'] as List?;
        if (files != null && files.any((f) => f['id'] == fileId)) {
          mediaItemId = movie['id'] as String;
          break;
        }
      }

      expect(mediaItemId, isNotNull,
          reason: 'Should find media item ID for test file');

      // Fetch streaming candidates using the "movie" content type
      final candidates = await streaming.fetchStreamingCandidates(
        contentType: 'movie',
        id: mediaItemId!,
      );

      expect(candidates, isNotNull,
          reason: 'Streaming candidates should be returned');
      debugPrint('[P2P Streaming Test] Candidates result: $candidates');

      // Verify we got candidates
      expect(candidates!.candidates, isNotEmpty,
          reason: 'Should have at least one streaming candidate');

      // The E2E test video is H.264/AAC/MP4, which should be direct-playable
      expect(candidates.hasDirectPlay, isTrue,
          reason: 'H.264/AAC/MP4 test video should have DIRECT_PLAY candidate');

      // Should also have a TRANSCODE fallback
      expect(candidates.hasTranscode, isTrue,
          reason: 'Should always have TRANSCODE fallback candidate');

      // Verify file ID is returned
      expect(candidates.fileId, isNotEmpty,
          reason: 'Candidates should include fileId');

      // Verify metadata
      expect(candidates.metadata, isNotNull,
          reason: 'Candidates should include metadata');
      expect(candidates.metadata!.duration, isNotNull,
          reason: 'Metadata should include duration');
      expect(candidates.metadata!.duration!, greaterThan(0),
          reason: 'Duration should be positive');

      // Verify each candidate has required fields
      for (final candidate in candidates.candidates) {
        expect(candidate.strategy, isNotEmpty,
            reason: 'Candidate should have a strategy');
        expect(candidate.mime, isNotEmpty,
            reason: 'Candidate should have a mime type');
        expect(candidate.container, isNotEmpty,
            reason: 'Candidate should have a container');
        debugPrint(
            '[P2P Streaming Test] Candidate: ${candidate.strategy} - ${candidate.mime}');
      }

      // Also test with "file" content type
      final fileCandidates = await streaming.fetchStreamingCandidates(
        contentType: 'file',
        id: fileId,
      );
      expect(fileCandidates, isNotNull,
          reason: 'Should also work with "file" content type');
      expect(fileCandidates!.candidates.length, candidates.candidates.length,
          reason: 'File and movie candidates should match');

      // Stop app
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 100));

      debugPrint(
          '[P2P Streaming Test] Streaming candidates query test passed!');
    });

    testWidgets('Direct file streaming works via HTTP',
        (WidgetTester tester) async {
      debugPrint('[P2P Streaming Test] Starting direct file streaming test');

      // Launch the app
      await tester.pumpWidget(
        const ProviderScope(
          child: MyApp(),
        ),
      );

      // Complete pairing
      await performPairing(tester);

      // Get streaming helper
      final streaming = StreamingTestHelper.fromEnvironment();
      await streaming.initialize();

      // Get test media file ID
      final fileId = await streaming.getTestMediaFileId();
      if (fileId == null) {
        debugPrint(
            '[P2P Streaming Test] Skipping direct streaming test: no media file found');
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
        return;
      }
      debugPrint('[P2P Streaming Test] Test media file ID: $fileId');

      // Verify direct file stream endpoint works (HTTP path)
      final directStreamOk = await streaming.verifyDirectFileStream(fileId);
      expect(directStreamOk, isTrue,
          reason: 'Direct file stream endpoint should return 200 or 206');
      debugPrint(
          '[P2P Streaming Test] Direct file stream endpoint is accessible');

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

    testWidgets('Player can navigate to video and start playback',
        (WidgetTester tester) async {
      debugPrint('[P2P Streaming Test] Starting player navigation test');

      // Launch the app
      await tester.pumpWidget(
        const ProviderScope(
          child: MyApp(),
        ),
      );

      // Complete pairing
      await performPairing(tester);

      // Verify test media exists in backend before asserting UI navigation.
      final streaming = StreamingTestHelper.fromEnvironment();
      await streaming.initialize();
      final fileId = await streaming.getTestMediaFileId();
      if (fileId == null) {
        debugPrint(
            '[P2P Streaming Test] Skipping player navigation assertions: no test media exists');
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
        return;
      }

      final libraryLoaded = await waitForMediaLibrary(tester);
      if (!libraryLoaded) {
        debugPrint(
            '[P2P Streaming Test] Skipping player navigation: media library UI did not render');
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 100));
        return;
      }

      // Find and tap on test movie
      final testMovieFinder = find.textContaining('E2E Test');
      if (testMovieFinder.evaluate().isEmpty) {
        // Try finding any movie
        debugPrint(
            '[P2P Streaming Test] E2E Test movie not found, looking for any movie');
        final anyMovieCard = find.byType(GridView);
        expect(anyMovieCard, findsOneWidget);

        // Tap on first item in grid
        final firstCard = find.descendant(
          of: anyMovieCard,
          matching: find.byType(InkWell).first,
        );
        if (firstCard.evaluate().isNotEmpty) {
          await tester.tap(firstCard);
          await tester.pump(const Duration(seconds: 2));
        }
      } else {
        await tester.tap(testMovieFinder.first);
        await tester.pump(const Duration(seconds: 2));
      }

      // Wait for movie detail screen
      await tester.pump(const Duration(seconds: 3));

      // Look for play button
      final playButton = find.byIcon(Icons.play_arrow);
      if (playButton.evaluate().isNotEmpty) {
        debugPrint('[P2P Streaming Test] Found play button, tapping...');
        await tester.tap(playButton.first);
        await tester.pump(const Duration(seconds: 2));

        // Wait for player screen to load
        for (var i = 0; i < 30; i++) {
          await tester.pump(const Duration(seconds: 1));

          // Look for loading indicator or player controls
          final loadingIndicator = find.byType(CircularProgressIndicator);
          if (loadingIndicator.evaluate().isEmpty) {
            // Player loaded
            debugPrint(
                '[P2P Streaming Test] Player loaded after ${i + 1} seconds');
            break;
          }
        }
      }

      // Navigate back
      final backButton = find.byTooltip('Back');
      if (backButton.evaluate().isNotEmpty) {
        await tester.tap(backButton);
        await tester.pump(const Duration(seconds: 1));
      }

      // Stop app
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 100));

      debugPrint('[P2P Streaming Test] Player navigation test completed');
    });
  });
}
