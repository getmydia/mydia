import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'e2e_api_client.dart';

/// Helper class for streaming integration tests.
///
/// This helper provides utilities for:
/// - Finding test media
/// - Starting streaming sessions
/// - Waiting for HLS playlists to be ready
/// - Verifying P2P connections
/// - Checking streaming health
class StreamingTestHelper {
  final E2eApiClient _api;
  final String _mydiaUrl;

  /// Media IDs discovered during tests
  // ignore: unused_field
  String? _testMediaItemId;
  String? _testMediaFileId;

  StreamingTestHelper({
    required E2eApiClient api,
    required String mydiaUrl,
  })  : _api = api,
        _mydiaUrl = mydiaUrl;

  /// Creates a StreamingTestHelper from environment variables.
  factory StreamingTestHelper.fromEnvironment() {
    final api = E2eApiClient.fromEnvironment();
    final mydiaUrl = Platform.environment['MYDIA_URL'] ?? 'http://mydia:4000';

    return StreamingTestHelper(
      api: api,
      mydiaUrl: mydiaUrl,
    );
  }

  /// Login and initialize the helper.
  Future<void> initialize() async {
    await _api.login();
  }

  /// Auth headers for authenticated HTTP requests (HLS endpoints require auth).
  Map<String, String> get _authHeaders {
    final token = _api.authToken;
    if (token != null) {
      return {'Authorization': 'Bearer $token'};
    }
    return {};
  }

  /// Get the test media file ID for streaming tests.
  ///
  /// This queries for the test video created during E2E setup.
  /// Returns the media file ID or null if not found.
  Future<String?> getTestMediaFileId() async {
    if (_testMediaFileId != null) {
      return _testMediaFileId;
    }

    // Query for test media using connection/edges format
    const query = r'''
      query GetTestMedia {
        movies(first: 50) {
          edges {
            node {
              id
              title
              files {
                id
                size
              }
            }
          }
        }
      }
    ''';

    try {
      final response = await _api.graphqlRequest(query, {});

      if (response['errors'] != null) {
        return null;
      }

      final edges = response['data']['movies']['edges'] as List?;
      if (edges == null || edges.isEmpty) {
        return null;
      }

      // Find the test video
      for (final edge in edges) {
        final movie = edge['node'];
        final title = movie['title'] as String?;
        if (title != null && title.contains('E2E Test')) {
          final files = movie['files'] as List?;
          if (files != null && files.isNotEmpty) {
            _testMediaItemId = movie['id'] as String;
            _testMediaFileId = files.first['id'] as String;
            return _testMediaFileId;
          }
        }
      }

      // If no E2E test video found, use the first available
      final firstMovie = edges.first['node'];
      final files = firstMovie['files'] as List?;
      if (files != null && files.isNotEmpty) {
        _testMediaItemId = firstMovie['id'] as String;
        _testMediaFileId = files.first['id'] as String;
        return _testMediaFileId;
      }

      return null;
    } catch (e) {
      return null;
    }
  }

  /// Start a streaming session for the test media.
  ///
  /// Returns the session ID and HLS URL, or null if failed.
  Future<StreamingSession?> startStreamingSession({
    String strategy = 'HLS_COPY',
  }) async {
    final fileId = await getTestMediaFileId();
    if (fileId == null) {
      throw StateError('No test media file available');
    }

    final mutation = r'''
      mutation StartStreamingSession($fileId: ID!, $strategy: StreamingStrategy!) {
        startStreamingSession(fileId: $fileId, strategy: $strategy) {
          sessionId
          duration
        }
      }
    ''';

    final response = await _api.graphqlRequest(mutation, {
      'fileId': fileId,
      'strategy': strategy,
    });

    if (response['errors'] != null) {
      final errors = response['errors'] as List;
      throw Exception('Failed to start streaming: ${errors.first['message']}');
    }

    final data = response['data']['startStreamingSession'];
    final sessionId = data['sessionId'] as String;
    // Construct HLS URL client-side from session ID
    final hlsUrl = '$_mydiaUrl/api/v1/hls/$sessionId/index.m3u8';

    return StreamingSession(
      sessionId: sessionId,
      hlsUrl: hlsUrl,
      duration: data['duration'] != null
          ? (data['duration'] as num).toDouble()
          : null,
      fileId: fileId,
    );
  }

  /// End a streaming session.
  Future<void> endStreamingSession(String sessionId) async {
    final mutation = r'''
      mutation EndStreamingSession($sessionId: String!) {
        endStreamingSession(sessionId: $sessionId)
      }
    ''';

    await _api.graphqlRequest(mutation, {'sessionId': sessionId});
  }

  /// Wait for an HLS playlist to be ready.
  ///
  /// The playlist is considered ready when it has at least [minSegments]
  /// .ts segments available.
  Future<bool> waitForHlsPlaylist(
    String playlistUrl, {
    int minSegments = 3,
    int maxRetries = 20,
    Duration retryDelay = const Duration(milliseconds: 500),
  }) async {
    for (var i = 0; i < maxRetries; i++) {
      try {
        final response =
            await http.get(Uri.parse(playlistUrl), headers: _authHeaders);

        if (response.statusCode == 200) {
          final playlistText = response.body;
          final segmentCount = '.ts'.allMatches(playlistText).length;

          if (segmentCount >= minSegments) {
            return true;
          }
        }
      } catch (e) {
        // Connection errors are expected while stream initializes
      }

      await Future<void>.delayed(retryDelay);
    }

    return false;
  }

  /// Wait for segment data to be available.
  ///
  /// Attempts to fetch a segment from the HLS stream.
  Future<bool> waitForSegmentData(
    String baseUrl, {
    int maxRetries = 10,
    Duration retryDelay = const Duration(seconds: 1),
  }) async {
    // First get the playlist
    final playlistUrl =
        baseUrl.endsWith('.m3u8') ? baseUrl : '$baseUrl/index.m3u8';

    for (var i = 0; i < maxRetries; i++) {
      try {
        final response =
            await http.get(Uri.parse(playlistUrl), headers: _authHeaders);

        if (response.statusCode == 200) {
          final playlistText = response.body;

          // Extract first segment URL
          final segmentMatch =
              RegExp(r'segment_\d+\.ts').firstMatch(playlistText);
          if (segmentMatch != null) {
            final segmentName = segmentMatch.group(0);
            final segmentUrl = baseUrl.endsWith('.m3u8')
                ? baseUrl.replaceFirst('index.m3u8', segmentName!)
                : '$baseUrl/$segmentName';

            // Try to fetch the segment
            final segmentResponse =
                await http.get(Uri.parse(segmentUrl), headers: _authHeaders);
            if (segmentResponse.statusCode == 200 &&
                segmentResponse.bodyBytes.isNotEmpty) {
              return true;
            }
          }
        }
      } catch (e) {
        // Connection errors are expected while stream initializes
      }

      await Future<void>.delayed(retryDelay);
    }

    return false;
  }

  /// Get P2P connection status from the server.
  Future<P2pConnectionStatus> getP2pConnectionStatus() async {
    const query = r'''
      query GetRemoteAccessStatus {
        remoteAccessStatus {
          enabled
          endpointAddr
          connectedPeers
        }
      }
    ''';

    try {
      final response = await _api.graphqlRequest(query, {});

      if (response['errors'] != null) {
        return P2pConnectionStatus(disconnected: true);
      }

      final data = response['data']['remoteAccessStatus'];
      return P2pConnectionStatus(
        enabled: data['enabled'] as bool? ?? false,
        endpointAddr: data['endpointAddr'] as String?,
        connectedPeers: data['connectedPeers'] as int? ?? 0,
        disconnected: false,
      );
    } catch (e) {
      return P2pConnectionStatus(disconnected: true);
    }
  }

  /// Wait for P2P connection to be established.
  Future<bool> waitForP2pConnection({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final deadline = DateTime.now().add(timeout);

    while (DateTime.now().isBefore(deadline)) {
      final status = await getP2pConnectionStatus();

      if (status.enabled && status.connectedPeers > 0) {
        return true;
      }

      await Future<void>.delayed(const Duration(seconds: 1));
    }

    return false;
  }

  /// Get the direct HTTP stream URL for fallback testing.
  String getDirectStreamUrl(String fileId, {String strategy = 'HLS_COPY'}) {
    return '$_mydiaUrl/api/v1/stream/file/$fileId?strategy=$strategy';
  }

  /// Verify that a URL is reachable and returns valid content.
  Future<bool> verifyUrlAccessible(
    String url, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    try {
      final response = await http
          .get(Uri.parse(url), headers: _authHeaders)
          .timeout(timeout);

      return response.statusCode == 200 || response.statusCode == 206;
    } catch (e) {
      return false;
    }
  }

  /// Parse an HLS playlist and return segment URLs.
  List<String> parseSegmentUrls(String playlistContent, String baseUrl) {
    final segments = <String>[];
    final lines = const LineSplitter().convert(playlistContent);

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isNotEmpty &&
          !trimmed.startsWith('#') &&
          (trimmed.endsWith('.ts') || trimmed.endsWith('.m4s'))) {
        if (trimmed.startsWith('http')) {
          segments.add(trimmed);
        } else {
          // Relative URL
          final separator = baseUrl.endsWith('/') ? '' : '/';
          segments.add('$baseUrl$separator$trimmed');
        }
      }
    }

    return segments;
  }

  /// Get media info for the test media.
  ///
  /// Note: There is no top-level `mediaFile` query in the schema.
  /// Media file info is accessed via the parent movie's `files` field,
  /// which is already fetched by `getTestMediaFileId()`.
  Future<Map<String, dynamic>?> getTestMediaInfo() async {
    // No standalone mediaFile query exists in the schema.
    // Return null — callers use this only for optional debug output.
    return null;
  }

  /// Fetch streaming candidates for a media item via GraphQL.
  ///
  /// Returns candidates with strategies (DIRECT_PLAY, REMUX, HLS_COPY, TRANSCODE)
  /// and file metadata (duration, width, height).
  Future<StreamingCandidatesResult?> fetchStreamingCandidates({
    required String contentType,
    required String id,
  }) async {
    const query = r'''
      query StreamingCandidates($contentType: String!, $id: ID!) {
        streamingCandidates(contentType: $contentType, id: $id) {
          fileId
          candidates {
            strategy
            mime
            container
            videoCodec
            audioCodec
          }
          metadata {
            duration
            width
            height
          }
        }
      }
    ''';

    try {
      final response = await _api.graphqlRequest(query, {
        'contentType': contentType,
        'id': id,
      });

      if (response['errors'] != null) {
        final errors = response['errors'] as List;
        throw Exception(
            'Streaming candidates query failed: ${errors.first['message']}');
      }

      final data = response['data']['streamingCandidates'];
      if (data == null) return null;

      final candidates = (data['candidates'] as List)
          .map((c) => StreamingCandidate(
                strategy: c['strategy'] as String,
                mime: c['mime'] as String,
                container: c['container'] as String,
                videoCodec: c['videoCodec'] as String?,
                audioCodec: c['audioCodec'] as String?,
              ))
          .toList();

      final metadata = data['metadata'] as Map<String, dynamic>?;

      return StreamingCandidatesResult(
        fileId: data['fileId'] as String,
        candidates: candidates,
        metadata: metadata != null
            ? StreamingMetadata(
                duration: (metadata['duration'] as num?)?.toDouble(),
                width: metadata['width'] as int?,
                height: metadata['height'] as int?,
              )
            : null,
      );
    } catch (e) {
      rethrow;
    }
  }

  /// Verify that a direct file stream endpoint returns valid content.
  ///
  /// Tests GET /api/v1/stream/file/:fileId and checks for HTTP 200/206.
  Future<bool> verifyDirectFileStream(String fileId) async {
    final url = '$_mydiaUrl/api/v1/stream/file/$fileId';
    try {
      final request = http.Request('GET', Uri.parse(url));
      request.headers.addAll(_authHeaders);
      // Request only the first 1KB to avoid downloading the entire file
      request.headers['Range'] = 'bytes=0-1023';

      final streamedResponse = await request.send();
      final statusCode = streamedResponse.statusCode;

      // 200 (full content) or 206 (partial content) are both valid
      return statusCode == 200 || statusCode == 206;
    } catch (e) {
      return false;
    }
  }
}

/// Information about a streaming session.
class StreamingSession {
  final String sessionId;
  final String? hlsUrl;
  final double? duration;
  final String fileId;

  StreamingSession({
    required this.sessionId,
    this.hlsUrl,
    this.duration,
    required this.fileId,
  });

  bool get hasHlsUrl => hlsUrl != null && hlsUrl!.isNotEmpty;

  @override
  String toString() {
    return 'StreamingSession(sessionId: $sessionId, hlsUrl: $hlsUrl, duration: $duration)';
  }
}

/// Result of the streaming candidates query.
class StreamingCandidatesResult {
  final String fileId;
  final List<StreamingCandidate> candidates;
  final StreamingMetadata? metadata;

  StreamingCandidatesResult({
    required this.fileId,
    required this.candidates,
    this.metadata,
  });

  /// Whether any candidate supports direct play.
  bool get hasDirectPlay => candidates.any((c) => c.strategy == 'DIRECT_PLAY');

  /// Whether any candidate supports HLS copy.
  bool get hasHlsCopy => candidates.any((c) => c.strategy == 'HLS_COPY');

  /// Whether any candidate supports transcoding.
  bool get hasTranscode => candidates.any((c) => c.strategy == 'TRANSCODE');

  @override
  String toString() {
    final strategies = candidates.map((c) => c.strategy).join(', ');
    return 'StreamingCandidatesResult(fileId: $fileId, strategies: [$strategies])';
  }
}

/// A single streaming candidate with strategy and codec info.
class StreamingCandidate {
  final String strategy;
  final String mime;
  final String container;
  final String? videoCodec;
  final String? audioCodec;

  StreamingCandidate({
    required this.strategy,
    required this.mime,
    required this.container,
    this.videoCodec,
    this.audioCodec,
  });

  @override
  String toString() {
    return 'StreamingCandidate(strategy: $strategy, mime: $mime, container: $container)';
  }
}

/// Metadata about a media file from the candidates query.
class StreamingMetadata {
  final double? duration;
  final int? width;
  final int? height;

  StreamingMetadata({
    this.duration,
    this.width,
    this.height,
  });

  @override
  String toString() {
    return 'StreamingMetadata(duration: $duration, width: $width, height: $height)';
  }
}

/// P2P connection status from the server.
class P2pConnectionStatus {
  final bool enabled;
  final String? endpointAddr;
  final int connectedPeers;
  final bool disconnected;

  P2pConnectionStatus({
    this.enabled = false,
    this.endpointAddr,
    this.connectedPeers = 0,
    required this.disconnected,
  });

  bool get isConnected => enabled && connectedPeers > 0;

  bool get isRelayConnection =>
      endpointAddr != null && endpointAddr!.contains('relay');

  @override
  String toString() {
    if (disconnected) {
      return 'P2pConnectionStatus(disconnected)';
    }
    return 'P2pConnectionStatus(enabled: $enabled, peers: $connectedPeers)';
  }
}
