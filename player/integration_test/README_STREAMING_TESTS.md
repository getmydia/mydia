# P2P Streaming Integration Tests

This document describes the integration tests created for the iroh-based P2P streaming functionality.

## Overview

The integration tests verify that HLS streaming works correctly over the P2P connection using the following components:

1. **Test Media Generation**: Auto-generated test video (5s, 720p, H.264/AAC)
2. **Streaming Test Helpers**: Utilities for managing streaming sessions
3. **E2E Integration Tests**: Full end-to-end tests of the streaming flow
4. **Unit Tests**: Local proxy service tests

## Files Created

### 1. Test Media Infrastructure

**File**: `scripts/e2e/seed.sh`
- **Changes**: Added test video generation and library seeding
- **What it does**:
  - Generates a 5-second 720p H.264/AAC test video using ffmpeg
  - Creates library path, media item, and media file records
  - Stores test media at `/media/movies/e2e-test-video.mp4`

**Test Media Details**:
- Resolution: 1280x720
- Duration: 5 seconds
- Video: H.264 (libx264), yuv420p
- Audio: AAC, 128kbps
- Format: MP4 with faststart

### 2. Streaming Test Helpers

**File**: `player/integration_test/helpers/streaming_helpers.dart`

**Key Classes**:

#### StreamingTestHelper
Main helper class for streaming tests:

```dart
// Initialize
final streaming = StreamingTestHelper.fromEnvironment();
await streaming.initialize();

// Get test media
final fileId = await streaming.getTestMediaFileId();

// Start streaming session
final session = await streaming.startStreamingSession(strategy: 'HLS_COPY');

// Wait for playlist
final ready = await streaming.waitForHlsPlaylist(session.hlsUrl!);

// Wait for segments
final segmentsReady = await streaming.waitForSegmentData(session.hlsUrl!);

// Clean up
await streaming.endStreamingSession(session.sessionId);

// Streaming candidates (new)
final candidates = await streaming.fetchStreamingCandidates(
  contentType: 'movie',
  id: mediaItemId,
);
print(candidates.hasDirectPlay); // true for H.264/AAC/MP4

// Direct file streaming
final ok = await streaming.verifyDirectFileStream(fileId);
```

#### StreamingCandidatesResult
Represents the result of a streaming candidates query:
- `fileId`: The resolved media file ID
- `candidates`: List of `StreamingCandidate` objects
- `metadata`: Optional `StreamingMetadata`
- `hasDirectPlay`: Whether DIRECT_PLAY is available
- `hasHlsCopy`: Whether HLS_COPY is available
- `hasTranscode`: Whether TRANSCODE is available

#### StreamingCandidate
A single streaming strategy candidate:
- `strategy`: One of DIRECT_PLAY, REMUX, HLS_COPY, TRANSCODE
- `mime`: RFC 6381 MIME type (e.g., `video/mp4; codecs="avc1.640028,mp4a.40.2"`)
- `container`: Container format (mp4, ts, mkv, etc.)
- `videoCodec`: Video codec string (nullable)
- `audioCodec`: Audio codec string (nullable)

#### StreamingMetadata
File metadata from the candidates query:
- `duration`: Duration in seconds
- `width`: Video width in pixels
- `height`: Video height in pixels

#### StreamingSession
Represents an active streaming session:
- `sessionId`: Unique session identifier
- `hlsUrl`: URL to the HLS playlist
- `duration`: Media duration in seconds
- `fileId`: Associated media file ID

#### P2pConnectionStatus
Represents P2P connection state:
- `enabled`: Whether remote access is enabled
- `endpointAddr`: P2P endpoint address
- `connectedPeers`: Number of connected peers
- `isConnected`: Convenience property

### 3. E2eApiClient Extensions

**File**: `player/integration_test/helpers/e2e_api_client.dart`

**Changes**:
- Made `graphqlRequest()` method public (was private `_graphqlRequest`)
- Allows test helpers to make custom GraphQL queries

### 4. P2P Streaming Integration Tests

**File**: `player/integration_test/p2p_streaming_test.dart`

**Test Scenarios**:

#### Test 1: Direct HTTP Streaming Works
- Completes device pairing
- Starts streaming session via GraphQL
- Verifies HLS playlist is ready
- Verifies segments are accessible
- Tests direct HTTP streaming path

#### Test 2: P2P Connection Can Be Established
- Completes device pairing
- Waits for P2P connection to establish
- Verifies connection status via GraphQL
- Confirms peer is connected

#### Test 3: P2P Streaming Works End-to-End
- Full P2P streaming test
- Establishes P2P connection, starts HLS session
- Verifies HLS playlist and segments over HTTP
- Tests streaming through the local proxy service

#### Test 4: Streaming Candidates Query Returns Valid Candidates
- Queries the `streamingCandidates` GraphQL query for test media
- Verifies DIRECT_PLAY candidate is present (H.264/AAC/MP4 test video)
- Verifies TRANSCODE fallback is always present
- Validates metadata (duration, width, height)
- Validates each candidate has strategy, mime, container fields
- Tests both "movie" and "file" content types

#### Test 5: Direct File Streaming Works via HTTP
- Tests the `/api/v1/stream/file/:id` REST endpoint
- Verifies HTTP 200/206 response with Range header support
- Validates that the direct stream URL is accessible
- Confirms the direct play path works without HLS transcoding

#### Test 6: Player Navigation and Playback
- Navigates to media library
- Finds and taps on test movie
- Taps play button
- Waits for player to load
- Tests UI integration

### 5. Local Proxy Service Unit Tests

**File**: `player/test/core/p2p/local_proxy_service_test.dart`

**Test Groups**:

#### Initialization Tests
- Starts on loopback address
- Throws when not started and URL methods called
- Can update target peer when running
- Stop clears all state

#### URL Building Tests
- Correct HLS URL format
- Correct base URL format
- URLs include actual bound port

#### HTTP Request Handling Tests
- 404 for non-HLS paths
- 400 for invalid HLS path format
- 503 when no target peer

#### Range Header Parsing Tests
- Full range: `bytes=0-1023`
- Open-ended: `bytes=1024-`
- Single byte: `bytes=0-0`
- Invalid format handling
- Missing header handling

#### CORS Headers Tests
- All responses include `Access-Control-Allow-Origin: *`

#### Response Handling Tests
- Correct content type
- Correct content length
- Content-Range for 206 responses
- Cache-Control forwarding

#### Error Handling Tests
- P2P request failures return 500
- Response already started handling
- Recovery from streaming errors

## Running the Tests

### Prerequisites

1. Docker and Docker Compose installed
2. `./dev` script available

### Build Test Environment

```bash
# Build all containers
./dev player e2e-build
```

### Run Integration Tests

```bash
# Run default E2E test (pairing flow)
./dev player e2e

# Run a specific integration test file
./dev player e2e --target integration_test/p2p_streaming_test.dart

# Rebuild Docker images only when needed
./dev player e2e --build
```

### Run Unit Tests

```bash
# Run local proxy service tests
./dev flutter test test/core/p2p/local_proxy_service_test.dart

# Run all P2P tests
./dev flutter test test/core/p2p/
```

## Test Architecture

### Data Flow

1. **Test Setup**:
   ```
   Docker Compose → Mydia Container → Test Video Generation → Library Seeding
   ```

2. **Integration Test Flow**:
   ```
   Linux Flutter App (xvfb) → Device Pairing → P2P Connection → HLS Request → Video Playback
   ```

3. **Streaming Candidates Flow**:
   ```
   Player → GraphQL Query (streamingCandidates) → Server analyzes codecs → Returns candidate strategies
   ```

4. **HTTP Streaming (HLS)**:
   ```
   Player → GraphQL Mutation → Server HLS Session → HLS Playlist → Segment Requests
   ```

5. **HTTP Streaming (Direct Play)**:
   ```
   Player → GET /api/v1/stream/file/:id → Server streams raw file → Range request support
   ```

6. **P2P Streaming (Direct Play)**:
   ```
   Player → Local Proxy (/direct/:fileId/stream) → P2P (session: direct:fileId) → Server → Raw file
   ```

7. **P2P Streaming (HLS Fallback)**:
   ```
   Player → Local Proxy (/hls/:sessionId/*) → P2P Service → iroh QUIC → Server → HLS Response
   ```

### Test Isolation

- Each test starts with fresh app instance
- Pumps `SizedBox.shrink()` to clean up between tests
- Streaming sessions cleaned up after each test
- P2P connections re-established per test

## Debugging Tests

### Enable Debug Logging

```bash
# Run with verbose output
./dev player e2e -- --verbose

# Run streaming test file with verbose output
./dev player e2e --target integration_test/p2p_streaming_test.dart -- --verbose
```

### Common Issues

1. **Test media not found**: Check ffmpeg generation in `scripts/e2e/seed.sh`
2. **Pairing timeout**: Verify claim code generation and relay service
3. **HLS playlist not ready**: Check transcoding timeout (30s)
4. **P2P connection fails**: Verify iroh relay is running

### Test Artifacts

Logs are available in:
- `docker compose -f compose.player-e2e.yml logs -f test` - Test container logs
- `compose.player-e2e.yml` - Service orchestration
- `Dockerfile.test` - Test runner configuration

## Future Enhancements

### Additional Tests to Add

1. **Resilience Tests**:
   - Connection drop during streaming
   - Network switching scenarios
   - Fallback to direct HTTP

2. **Performance Tests**:
   - Segment download speed
   - Connection establishment time
   - Buffer health monitoring

3. **Edge Cases**:
   - Empty playlist handling
   - Large file streaming
   - Multiple concurrent streams

4. **Mobile Platform Tests**:
   - Android integration tests
   - iOS integration tests (if applicable)

### Test Data Expansion

1. **Multiple Test Videos**:
   - Different resolutions (480p, 1080p, 4K)
   - Different codecs (H.264, HEVC, AV1)
   - Different audio formats (AAC, AC3, EAC3)

2. **TV Show Test Data**:
   - Episodes with season/episode numbers
   - Multiple seasons
   - Episode thumbnails

## Maintenance

### Updating Test Media

Edit the ffmpeg command in `scripts/e2e/seed.sh`:

```sh
ffmpeg -y -f lavfi -i testsrc2=duration=5:size=1280x720:rate=24 \
       -f lavfi -i sine=frequency=440:duration=5 \
       -c:v libx264 -preset ultrafast -crf 28 -pix_fmt yuv420p \
       -g 24 -keyint_min 24 \
       -c:a aac -b:a 128k \
       -movflags +faststart \
       /media/movies/e2e-test-video.mp4
```

### Adding New Test Scenarios

1. Add test method to `p2p_streaming_test.dart`
2. Use `StreamingTestHelper` for common operations
3. Add helper methods to `streaming_helpers.dart` if needed
4. Update this documentation

## References

- **Architecture**: See `AGENTS.md` for P2P architecture details
- **Protocol**: See `native/mydia_p2p_core/src/lib.rs` for HLS protocol implementation
- **Server**: See `lib/mydia/p2p/server.ex` for server-side streaming handlers
