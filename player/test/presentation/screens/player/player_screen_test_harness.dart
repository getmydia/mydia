// Shared scaffolding for tests that fully mount `PlayerScreen` — building a
// live `Player`/`ConsumerStatefulWidget` with real Riverpod providers and a
// real `MydiaClient` over a scripted transport. Not itself a test file (no
// `_test.dart` suffix), so `flutter test` does not try to run it directly.
//
// No such harness existed before the fix landed for the dispose()-time
// `ref.read` bug in `_terminateHlsSession` (see that method's doc comment in
// `player_screen.dart`): every test that mounted `PlayerScreen` and let it
// dispose hit `StateError: Using "ref" ... is unsafe`, unconditionally,
// because `BuildContext.mounted` is `false` throughout `State.dispose()` by
// core Flutter design. That is why `player_screen_key_handling_test.dart`
// only ever tested an extracted free function instead of the widget itself.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:player/core/sources/media_source.dart'
    show SourceConnectionStatus;
import 'package:player/core/sources/mydia/mydia_credentials.dart';
import 'package:player/core/sources/mydia/mydia_source.dart';
import 'package:player/core/sources/source.dart' show SourceId;
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/p2p/media_proxy_factory.dart';
import 'package:player/presentation/screens/player/session/mydia_playback_session.dart';
import 'package:player/core/cast/cast_providers.dart';
import 'package:player/core/cast/cast_session_manager.dart';
import 'package:player/core/downloads/download_providers.dart';
import 'package:player/core/downloads/download_service.dart';
import 'package:player/core/p2p/local_proxy_service.dart';
import 'package:player/core/p2p/media_proxy.dart';
import 'package:player/core/playback/local_playback_progress.dart';
import 'package:player/core/playback/playback_memory.dart';
import 'package:player/core/playback/playback_memory_providers.dart';
import 'package:player/core/playback/playback_progress_providers.dart';
import 'package:player/core/playback/playback_progress_store.dart';
import 'package:player/core/settings/settings_providers.dart';
import 'package:player/core/settings/settings_service.dart';
import 'package:player/core/window/player_window_sizer.dart';
import 'package:player/domain/models/cast_device.dart';
import 'package:player/domain/models/download.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/presentation/screens/player/player_screen.dart';
import 'package:player/presentation/screens/player/session/playback_session.dart';
import 'package:player/presentation/screens/settings/settings_controller.dart';

import '../../../test_utils/scripted_mydia_transport.dart';
import '../../../test_utils/toast_harness.dart';
import '../../../test_utils/mydia_test_source.dart';

/// How a harness source is reached: [HarnessLink.p2p] gives it a paired
/// instance's credentials, [HarnessLink.direct] a URL login.
class HarnessLink {
  // Not const, so the many call sites do not each need a `const` to satisfy
  // `prefer_const_constructors`.
  HarnessLink.direct()
      : isP2p = false,
        serverNodeAddr = null;
  HarnessLink.p2p({this.serverNodeAddr}) : isP2p = true;

  final bool isP2p;
  final String? serverNodeAddr;
}

/// The credentials a harness source carries for [link].
MydiaCredentials harnessCredentials(HarnessLink link) => link.isP2p
    ? MydiaCredentials(
        instanceId: 'inst-1',
        accessToken: 'access',
        nodeAddr: link.serverNodeAddr ?? 'test-node',
      )
    : const MydiaCredentials(
        instanceId: 'inst-1',
        accessToken: 'access',
        serverUrl: 'http://test.local',
      );

class FakeDownloadService extends Fake implements DownloadService {
  FakeDownloadService({this.downloaded});

  final DownloadedMedia? downloaded;

  @override
  DownloadedMedia? getDownloaded(ItemRef ref) => downloaded;
}

/// Captures the [CastLaunchRequest] handed to `startCast` instead of routing
/// or connecting to anything real.
class CapturingCastSessionManager extends Fake implements CastSessionManager {
  CastLaunchRequest? capturedRequest;

  /// Every request `startCast` was actually called with, in order.
  ///
  /// [capturedRequest] only ever holds the last one, which cannot tell a
  /// single legitimate cast from a stale load's call landing before the
  /// current load's own -- both leave the same last value behind. A test
  /// asserting a superseded load never reached `startCast` at all needs the
  /// full list instead.
  final List<CastLaunchRequest> capturedRequests = [];

  /// When set, `startCast` throws this instead of succeeding — simulating an
  /// unreachable receiver or a rejected codec, so a test can prove
  /// `_castToTargetIfSet` falls through to local playback on failure without
  /// clearing the chosen device (`castTargetProvider` stays set so the bar
  /// can offer a reconnect).
  Exception? startCastError;

  /// Every real-media position `seek` has been asked for, in order.
  ///
  /// Real positions, not receiver ones: `CastSessionManager.seek` is specified
  /// in the same coordinates `mediaInfo` publishes, and it owns the mapping
  /// (and the out-of-reach session restart) internally. A skip that recorded a
  /// receiver-relative value here would be asserting against the wrong space.
  final List<Duration> seekTargets = [];

  /// When set, `seek` throws it. A receiver that has gone away mid-playback is
  /// a routine state, not a hypothetical: the target is reachable over the
  /// network right up until it is not.
  Error? seekError;

  @override
  Future<void> startCast({
    required CastDevice device,
    required CastLaunchRequest request,
  }) async {
    capturedRequest = request;
    capturedRequests.add(request);
    final error = startCastError;
    if (error != null) throw error;
  }

  @override
  Future<void> seek(Duration position) async {
    seekTargets.add(position);
    final error = seekError;
    if (error != null) throw error;
  }
}

/// Answers the preference reads `PlayerScreen` makes at startup from memory.
///
/// The real [SettingsService] goes through `flutter_secure_storage`, whose
/// platform channel is not registered under `testWidgets`: the awaiting
/// Future never completes (the same trap documented on
/// [mockPathProviderDocumentsDirectory]). `_initializePlayer` awaits the
/// default-quality read before it decides anything, so an un-overridden
/// provider wedges initialization short of the resume prompt — every test
/// that mounts the screen fails on a dialog that never appears, with no
/// error to explain it.
class FakeSettingsService extends Fake implements SettingsService {
  FakeSettingsService({
    this.defaultQuality = 'auto',
    this.readError,
    this.writeError,
    this.autoSkipSegments = false,
  });

  /// The persisted `default_quality` key. `auto`, the real service's own
  /// default, reads back as `QualityRung.auto`.
  String defaultQuality;

  /// When set, reads throw it. `flutter_secure_storage` needs a keyring on
  /// Linux desktop, so an unreadable preference is a real state, not a
  /// hypothetical one.
  final Error? readError;

  /// When set, writes throw it.
  final Error? writeError;

  /// How many times the screen has asked storage for the default rung.
  /// Storage seeds the rung once per playback; the in-memory value carries
  /// it across every later re-initialization.
  int getDefaultQualityCalls = 0;

  /// How many times the screen has written a new default rung to storage.
  /// A fallback moves the session to Auto in memory only, so this must stay
  /// 0 across one.
  int setDefaultQualityCalls = 0;

  @override
  Future<String> getDefaultQuality() async {
    getDefaultQualityCalls++;
    final error = readError;
    if (error != null) throw error;
    return defaultQuality;
  }

  @override
  Future<void> setDefaultQuality(String quality) async {
    setDefaultQualityCalls++;
    final error = writeError;
    if (error != null) throw error;
    defaultQuality = quality;
  }

  /// Whether detected segments are skipped without asking. Off by default,
  /// matching the real preference, so a test that never mentions auto-skip
  /// exercises the manual button rather than racing against a seek.
  final bool autoSkipSegments;

  @override
  Future<bool> getAutoSkipSegments() async => autoSkipSegments;
}

/// Tracks whether the proxy was torn down, without touching a real P2P/HTTP
/// stack.
///
/// Mixes in the production [MediaProxyLeases], so ownership behaves here
/// exactly as it does in `LocalProxyService`: a test that mounts two screens
/// and unmounts one is asserting against the real rule, not a fake that was
/// taught the answer.
class TrackingLocalProxyService extends Fake
    with MediaProxyLeases
    implements LocalProxyService {
  /// Whether the proxy was actually torn down — the last owner let go, or
  /// something shut it down outright. Not merely "stop() was called": a stop
  /// from one of two owners is meant to be a no-op.
  bool stopped = false;
  bool startCalled = false;

  bool _running = false;

  /// Every file id direct playback has been pointed at, in order.
  ///
  /// This is the id that actually reaches the wire, which is the only thing
  /// that distinguishes "asked the server which file to play" from "reused a
  /// cached answer about a file that has since been deleted".
  final List<String> directStreamFileIds = [];

  @override
  int get port => 12345;

  /// The screen logs this when it starts the proxy, and `Fake` throws on any
  /// member it is not given.
  @override
  String get baseUrl => 'http://127.0.0.1:$port';

  /// Reflects real state rather than a hardcoded `true`, so a test can tell
  /// "still serving the screen that replaced me" from "torn down".
  @override
  bool get isRunning => _running;

  @override
  Future<void> start({
    required Object owner,
    required String targetPeer,
    String? authToken,
    required String target,
  }) async {
    acquireLease(owner);
    startCalled = true;
    _running = true;
  }

  @override
  String targetBaseUrl(String target) => baseUrl;

  @override
  String buildHlsUrl(String sessionId, {required String target}) =>
      'http://127.0.0.1:$port/hls/$sessionId/index.m3u8';

  @override
  String buildDirectStreamUrl(String fileId, {required String target}) {
    directStreamFileIds.add(fileId);
    return 'http://127.0.0.1:$port/direct/$fileId/stream';
  }

  @override
  Future<void> stop(Object owner, {required String target}) => release(owner);

  @override
  Future<void> release(Object owner) async {
    if (!releaseLease(owner)) return;
    stopped = true;
    _running = false;
  }

  @override
  Future<void> shutdown() async {
    clearLeases();
    stopped = true;
    _running = false;
  }
}

const testDevice = CastDevice(
  id: 'd1',
  name: 'Living Room',
  protocol: CastProtocolKind.chromecast,
);

/// Mocks the path_provider platform channel so `getApplicationDocumentsDirectory`
/// resolves instead of hanging.
///
/// `_resolveDownloadedFilePath` calls it as a fallback once the stored path
/// misses. Under `testWidgets`, unlike plain `test()`, an unmocked platform
/// channel does not fail fast with `MissingPluginException` — the awaiting
/// Future simply never completes, even across repeated `tester.pump()`
/// calls, so any test that exercises a non-null `downloaded` item hangs until
/// the runner's watchdog kills it.
///
/// Register from `setUp`, not `setUpAll`: a handler registered before the
/// per-test binding reset that precedes each `testWidgets` body does not
/// survive into it.
void mockPathProviderDocumentsDirectory() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (call) async => Directory.systemTemp.path,
  );
}

/// A downloaded item pointing at [filePath].
///
/// `_resolveDownloadedFilePath` checks `file_utils.fileExists(filePath)`
/// first, before it ever falls back to `path_provider`: pass a path to a
/// file that actually exists on disk (e.g. a real temp file the caller
/// creates and tears down) to drive the offline branch past its "downloaded
/// file not found" bail-out and into the shared resume/start path this test
/// suite cares about. Pass a path that does not exist — the default used to
/// hardcode one — to exercise that bail-out instead.
DownloadedMedia downloadedItem({
  required String filePath,
  int? runtimeMinutes,
}) =>
    DownloadedMedia(
      id: 'dl-1',
      mediaId: 'movie-1',
      title: 'The Long Aurora',
      quality: '1080p',
      filePath: filePath,
      fileSize: 1,
      mediaType: 'movie',
      downloadedAt: DateTime(2026, 1, 1),
      runtime: runtimeMinutes,
    );

/// Writes a local progress record into a container's store before the screen
/// mounts, standing in for a previous playback session.
Future<void> seedLocalProgress(
  ProviderContainer container, {
  String mediaId = 'movie-1',
  String mediaType = 'movie',
  int positionSeconds = 600,
  int durationSeconds = 5400,
  DateTime? updatedAt,
}) async {
  final store = await container.read(playbackProgressStoreProvider.future);
  await store.save(LocalPlaybackProgress(
    sourceId: testMydiaSourceId.value,
    mediaId: mediaId,
    mediaType: mediaType,
    positionSeconds: positionSeconds,
    durationSeconds: durationSeconds,
    updatedAt: updatedAt ?? DateTime.utc(2026, 8, 2, 12),
  ));
}

/// A well-formed `MovieDetail` response. All fields beyond the required ones
/// (`id`, `title`, `monitored`, `addedAt`, `isFavorite`) are omitted deliberately
/// so the fallback chain in `_resolveRealDuration` sees nothing from progress
/// or runtime unless [positionSeconds] or [durationSeconds] is supplied —
/// isolating whichever signal a given test wants to exercise.
///
/// [files] is likewise omitted by default: `MediaFileFragment` selects every
/// field it lists, so a test that supplies files has to hand back all of
/// them, not just the ones it cares about (see [mediaFileWithSubtitle] for a
/// ready-made one). This is what `_extractSubtitlesFromFiles` reads
/// `_subtitleTracks` from.
Map<String, dynamic> movieDetailResponse({
  int? positionSeconds,
  int? durationSeconds,
  List<Map<String, dynamic>>? files,
}) {
  return {
    '__typename': 'Query',
    'movie': {
      '__typename': 'Movie',
      'id': 'movie-1',
      'title': 'The Long Aurora',
      'monitored': false,
      'addedAt': '2026-01-01T00:00:00Z',
      'isFavorite': false,
      if (positionSeconds != null || durationSeconds != null)
        'progress': {
          '__typename': 'Progress',
          'positionSeconds': positionSeconds ?? 0,
          'durationSeconds': durationSeconds,
          'percentage': null,
          'watched': false,
          'lastWatchedAt': null,
        },
      if (files != null) 'files': files,
    },
  };
}

/// A single `MediaFileFragment` entry carrying one deliverable subtitle
/// track, in the shape `movieDetailResponse(files: [...])` and
/// `episodeDetailResponse`-style callers need.
///
/// Every field `MediaFileFragment` and its nested `subtitles` selection ask
/// for is present — a normalized-cache write rejects the whole query
/// (`PartialDataException`) if any selected field is missing from the
/// response, not just the ones a given test happens to read back.
///
/// [embedded] makes the track an in-container stream whose id is its ffprobe
/// stream index, as `trackId` then should be.
Map<String, dynamic> mediaFileWithSubtitle({
  String fileId = 'file-1',
  String trackId = '3',
  String language = 'eng',
  String title = 'English',
  // Nullable so a test can reproduce a just-downloaded sidecar, which
  // `SubtitleTrack.fromDownload` leaves with no url of its own.
  String? url = '/api/player/v1/subtitles/file/file-1/3?format=vtt',
  bool deliverable = true,
  bool forced = false,
  bool hearingImpaired = false,
  bool embedded = false,
}) {
  return {
    '__typename': 'MediaFile',
    'id': fileId,
    'resolution': null,
    'codec': null,
    'audioCodec': null,
    'hdrFormat': null,
    'size': null,
    'bitrate': null,
    'directPlaySupported': null,
    'streamUrl': null,
    'directPlayUrl': null,
    'subtitles': [
      {
        '__typename': 'SubtitleTrack',
        'trackId': trackId,
        'language': language,
        'title': title,
        'format': 'vtt',
        'embedded': embedded,
        'deliverable': deliverable,
        'forced': forced,
        'hearingImpaired': hearingImpaired,
        'url': url,
      },
    ],
  };
}

/// A `preferredSubtitle` object for [subtitlePreferenceResponse].
///
/// `mode` is the wire form, uppercase, which is what the generated enum
/// parses.
Map<String, dynamic> preferredSubtitleObject({
  required String mode,
  String? language,
  bool forced = false,
  bool hearingImpaired = false,
  String? trackTitle,
}) {
  return {
    '__typename': 'SubtitlePreference',
    'mode': mode,
    'language': language,
    'forced': forced,
    'hearingImpaired': hearingImpaired,
    'trackTitle': trackTitle,
  };
}

/// A well-formed `MovieSubtitlePreference` response, or the `episode` one when
/// [root] says so.
///
/// The preference is its own document rather than a field on
/// `MediaFileFragment` -- see `subtitle_preference.graphql` for why. It fires
/// chained after the detail query but concurrently with segments and subtitle
/// offsets (see `_fetchProgressAndEpisodes`'s dartdoc), so an ordered
/// `ScriptedMydiaTransport.responses` script can no longer carry it in a fixed
/// slot -- dispatch on the operation instead (see [movieSegmentsResponse]'s
/// dartdoc).
/// The defaults are the movie all those scripts open on, with no stored
/// choice on its one file, which is what every test that is not about the
/// preference wants.
///
/// [preferences] maps a file id to its `preferredSubtitle` object; a file left
/// out of it has no preference, which is the same answer as an explicit null.
Map<String, dynamic> subtitlePreferenceResponse({
  String root = 'movie',
  String id = 'movie-1',
  Map<String, Map<String, dynamic>?> preferences = const {'file-1': null},
}) {
  return {
    '__typename': 'Query',
    root: {
      '__typename': root == 'movie' ? 'Movie' : 'Episode',
      'id': id,
      'files': [
        for (final entry in preferences.entries)
          {
            '__typename': 'MediaFile',
            'id': entry.key,
            'preferredSubtitle': entry.value,
          },
      ],
    },
  };
}

/// A well-formed `MovieSegments` response.
///
/// `_fetchProgressAndEpisodes` fires this concurrently with the detail query,
/// the subtitle offsets query, and (via `runIsolated`) streaming candidates,
/// so an ordered `ScriptedMydiaTransport.responses` script can no longer carry
/// it in a fixed slot -- dispatch a `ScriptedMydiaTransport((request, _) => ...)`
/// on the operation instead (see `player/docs/testing.md`). Segments travel in their own
/// document on purpose, not inside `MediaFileFragment` — see
/// `player_screen_segments_isolation_test.dart` for why. The default is
/// "detection found nothing", which is what every test that is not about
/// segments wants.
Map<String, dynamic> movieSegmentsResponse({
  List<Map<String, dynamic>> segments = const [],
}) {
  return {
    '__typename': 'Query',
    'movie': {
      '__typename': 'Movie',
      'id': 'movie-1',
      'files': [
        {
          '__typename': 'MediaFile',
          'id': 'file-1',
          'segments': segments,
        },
      ],
    },
  };
}

/// A well-formed `SubtitleTrackSettings` response: no track has a stored
/// correction, which is the default every test that is not about subtitle
/// delay wants.
///
/// `_fetchProgressAndEpisodes` fires this concurrently with the other
/// pre-play queries -- see `movieSegmentsResponse`'s dartdoc for why an
/// ordered `ScriptedMydiaTransport.responses` script can no longer carry it in
/// a fixed slot. An empty list here leaves the controller's loaded flag true and
/// its stored offsets empty, so nothing downstream (mpv's sub-delay, the
/// sheet's delay row) departs from zero.
Map<String, dynamic> subtitleTrackSettingsResponse({
  List<Map<String, dynamic>> settings = const [],
}) {
  return {
    '__typename': 'Query',
    'subtitleTrackSettings': settings,
  };
}

/// A well-formed `StreamingCandidates` response.
///
/// Empty `candidates` (the default) forces the HLS/TRANSCODE path, because
/// `_canDirectPlay` declines an empty list. Pass [directPlay] to put a
/// `DIRECT_PLAY` candidate first instead, which is what makes
/// `_initializePlayer` take its native direct-play branch.
///
/// Every field the document selects must be present, including the ones a
/// given test does not care about: the normalized cache refuses a partial
/// write, which surfaces as `result.hasException` and makes
/// `_fetchStreamingCandidates` return null — indistinguishable, from the
/// screen's point of view, from a server that knows nothing about the file.
///
/// [height] feeds `deriveQualityLadder`. Null (the default) collapses the
/// ladder to Original alone, which hides the quality control — what every
/// test that is not about quality wants.
///
/// [fileId] is parameterised because this response is what the direct-play
/// branch takes its file id from, in preference to the one on the route. A
/// test that needs to tell a fresh answer apart from a stale cached one has to
/// be able to make the two differ.
Map<String, dynamic> streamingCandidatesResponse({
  double? duration,
  bool directPlay = false,
  int? height,
  int? bitrate,
  String fileId = 'file-1',
  List<String>? preferredAudioLanguages,
}) {
  return {
    '__typename': 'Query',
    'streamingCandidates': {
      '__typename': 'StreamingCandidatesResult',
      'fileId': fileId,
      'candidates': <dynamic>[
        if (directPlay)
          {
            '__typename': 'StreamingCandidate',
            'strategy': 'DIRECT_PLAY',
            'mime': 'video/mp4; codecs="avc1.640028, mp4a.40.2"',
            'container': 'mp4',
            'videoCodec': 'avc1.640028',
            'audioCodec': 'mp4a.40.2',
          },
      ],
      // Every field the StreamingCandidates document selects has to be here.
      // graphql's normalizer rejects a partial object outright — the whole
      // query fails with PartialDataException, not just the missing field —
      // so omitting one breaks tests that never mention it.
      'metadata': {
        '__typename': 'StreamingMetadata',
        'duration': duration,
        'width': null,
        'height': height,
        'bitrate': bitrate,
        'preferredAudioLanguages': preferredAudioLanguages,
      },
    },
  };
}

/// A well-formed `StartStreamingSession` response. [startPosition],
/// [maxBitrate] and [maxHeight] are the *echoed* values the server claims to
/// have applied — deliberately separate parameters from whatever the client
/// requested, so tests can make them differ on purpose (a relay clamps both
/// caps below the request).
///
/// [playlistMode] defaults to `WINDOW`, not `FULL`: every test written
/// before full-playlist support existed encodes windowed-mode assumptions
/// (an echoed offset that matters, a timeline built from it, a session that
/// restarts on a far seek), and defaulting to `FULL` here would silently
/// flip all of them onto the identity timeline instead. Tests exercising the
/// full-playlist path pass `playlistMode: 'FULL'` explicitly.
Map<String, dynamic> startStreamingSessionResponse({
  String sessionId = 'sess-1',
  double? duration,
  int? startPosition,
  int? maxBitrate,
  int? maxHeight,
  String playlistMode = 'WINDOW',
}) {
  return {
    '__typename': 'RootMutationType',
    'startStreamingSession': {
      '__typename': 'StreamingSessionResult',
      'sessionId': sessionId,
      'duration': duration,
      'startPosition': startPosition,
      'maxBitrate': maxBitrate,
      'maxHeight': maxHeight,
      'playlistMode': playlistMode,
    },
  };
}

/// What a server that predates the height cap answers the legacy document
/// with: no `maxBitrate` or `maxHeight` keys at all, because its schema has
/// no such fields for that document to select.
///
/// Distinct from passing nulls to [startStreamingSessionResponse], which
/// still sends the keys and so would not exercise the generated `fromJson`
/// reading them as absent.
Map<String, dynamic> legacyStartStreamingSessionResponse({
  String sessionId = 'sess-1',
  double? duration,
  int? startPosition,
}) {
  return {
    '__typename': 'RootMutationType',
    'startStreamingSession': {
      '__typename': 'StreamingSessionResult',
      'sessionId': sessionId,
      'duration': duration,
      'startPosition': startPosition,
    },
  };
}

Map<String, dynamic> endStreamingSessionResponse({bool ok = true}) {
  return {
    '__typename': 'RootMutationType',
    'endStreamingSession': ok,
  };
}

/// Builds a [ProviderContainer] with the overrides every `PlayerScreen` mount
/// needs, wiring [server] as the transport of the test Mydia source and
/// [connectionState] as that source's credentials (p2p carries a node
/// address, direct a URL), with [castManager]/[proxyService] standing in for
/// the pieces a real app would resolve from native services this test has no
/// business touching.
///
/// Returns a [ProviderContainer] directly rather than the raw override list:
/// `Override` (the element type `ProviderContainer.overrides` expects) is not
/// part of `flutter_riverpod`'s public export surface, so a helper can only
/// spell its return type by constructing the container itself.
ProviderContainer buildPlayerScreenContainer({
  required ScriptedMydiaTransport server,
  required HarnessLink connectionState,
  required CapturingCastSessionManager castManager,
  required TrackingLocalProxyService proxyService,
  DownloadedMedia? downloaded,
  // Overrides [downloaded] when a test needs a lookup that depends on the
  // item asked for.
  DownloadService? downloadService,
  // The bound Mydia instance reports itself unreachable.
  bool offline = false,
  PlaybackProgressStore? progressStore,
  // Further Mydia instances registered next to the test one.
  Map<SourceId, MydiaSource> extraSources = const {},
  SettingsService? settingsService,
  // Deliberately not defaulted the way [settingsService] is:
  // `settingsServiceProvider` and `coreSettingsServiceProvider` are two
  // independent providers (see `settings_providers.dart`'s own doc comment
  // for why), so overriding one never reaches the other. Null leaves
  // `coreSettingsServiceProvider` at its real, unoverridden default, which
  // every test but the stats-panel ones already relies on.
  SettingsService? coreSettingsService,
  Stream<CastSession?>? castSessionStream,
  // Holds `castSessionManagerProvider`'s own future open until a test
  // completes it, so a load parked inside `_castToTargetIfSet`'s
  // `await ref.read(castSessionManagerProvider.future)` can be superseded
  // by a later switch before the manager ever resolves -- the race
  // `_castToTargetIfSet`'s `loadGeneration` check closes. `FutureProvider`
  // caches the one Future this override produces, so every load's read
  // during a test shares it and unparks together when it completes.
  Completer<void>? castManagerGate,
  // Completed the instant the override above starts awaiting
  // [castManagerGate] -- before that, a test cannot tell "the parked read
  // has not happened yet" from "it has and is waiting", and a fixed pump
  // duration guesses at which one it is. Ignored when [castManagerGate] is
  // null.
  Completer<void>? castManagerRequested,
}) {
  final creds = harnessCredentials(connectionState);
  final base = testMydiaSourceOver(server, creds: creds, accountId: 'macct');
  final MydiaSource source = offline
      ? MydiaSource(
          source: base.source,
          client: base.client,
          status: ValueNotifier(SourceConnectionStatus.unreachable),
        )
      : base;
  return ProviderContainer(overrides: [
    mediaSourceProvider(testMydiaSourceId).overrideWithValue(source),
    for (final entry in extraSources.entries)
      mediaSourceProvider(entry.key).overrideWithValue(entry.value),
    settingsServiceProvider
        .overrideWithValue(settingsService ?? FakeSettingsService()),
    if (coreSettingsService != null)
      coreSettingsServiceProvider.overrideWithValue(coreSettingsService),
    downloadManagerProvider.overrideWith((ref) async =>
        downloadService ?? FakeDownloadService(downloaded: downloaded)),
    localProxyServiceProvider.overrideWithValue(proxyService),
    castSessionManagerProvider.overrideWith((ref) async {
      final gate = castManagerGate;
      if (gate != null) {
        if (castManagerRequested?.isCompleted == false) {
          castManagerRequested!.complete();
        }
        await gate.future;
      }
      return castManager;
    }),
    // Null by default: no receiver, so `isCastingProvider` stays false and the
    // screen builds its local body. Pass a stream to stand in for a live cast,
    // which is the only way to reach `CastPlaceholderView`: the real
    // provider derives from `CastSessionManager`, and the fake above has no
    // session machinery to drive it.
    castSessionProvider
        .overrideWith((ref) => castSessionStream ?? Stream.value(null)),
    playbackProgressStoreProvider.overrideWith(
        (ref) async => progressStore ?? InMemoryPlaybackProgressStore()),
    playbackMemoryProvider
        .overrideWith((ref) async => InMemoryPlaybackMemory()),
  ]);
}

/// Mounts `PlayerScreen` under [container] and pumps once.
///
/// [createPlayer] is the screen's own seam for the media_kit `Player`: pass a
/// factory whose player wraps a fake `PlatformPlayer` when the test needs to
/// reach real playback, since mpv/FFI is unavailable under `flutter test`.
/// Omitted, the screen builds a real `Player` exactly as it does in
/// production.
Future<void> pumpPlayerScreen(
  WidgetTester tester,
  ProviderContainer container, {
  String mediaId = 'movie-1',
  String mediaType = 'movie',
  String fileId = 'file-1',
  String? showId,
  int? seasonNumber,
  PlaybackSession? session,
  Player Function()? createPlayer,
  PlayerWindowSizer Function()? createWindowSizer,
}) async {
  session ??= MydiaPlaybackSession(
    source:
        container.read(mediaSourceProvider(testMydiaSourceId)) as MydiaSource,
    item: ItemRef(
      sourceId: testMydiaSourceId,
      kind: mediaType == 'episode' ? ItemKind.episode : ItemKind.movie,
      externalId: mediaId,
    ),
    fileId: fileId,
    showId: showId,
    seasonNumber: seasonNumber,
    proxy: () => container.read(mediaProxyProvider),
  );
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      builder: toastLayerBuilder,
      home: PlayerScreen(
        mediaId: mediaId,
        mediaType: mediaType,
        fileId: fileId,
        showId: showId,
        seasonNumber: seasonNumber,
        title: 'The Long Aurora',
        session: session,
        createPlayer: createPlayer,
        createWindowSizer: createWindowSizer,
      ),
    ),
  ));
  await tester.pump();
}

/// Pumps in small steps until [condition] is satisfied or [maxTries] is hit.
/// Deliberately not `pumpAndSettle`: `PlayerScreen` shows a
/// `CircularProgressIndicator` while `_isLoading` is true, whose implicit
/// animation never settles, so `pumpAndSettle` would time out.
Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  int maxTries = 100,
}) async {
  for (var i = 0; i < maxTries && !condition(); i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

/// Polls [condition] until it is satisfied or [ceiling] elapses, yielding to
/// the real event loop between checks.
///
/// For tests whose `_initializePlayer` path depends on real asynchronous I/O
/// — `dart:io` file checks, a `path_provider` platform-channel round trip
/// (see [mockPathProviderDocumentsDirectory]'s doc comment for why those
/// never resolve under plain `tester.pump()`) — a fixed pump-count budget is
/// either wastefully long or, on a slower/loaded machine, flaky-short. This
/// polls the actual outcome instead of guessing a duration, with a ceiling
/// generous enough that hitting it means something is genuinely stuck, not
/// just slow.
///
/// Must be called from inside `tester.runAsync(() async { ... })`: the real
/// `Future.delayed` between pumps is what yields to the real event loop for
/// pending I/O to complete, and that only takes effect inside `runAsync`.
Future<void> pumpUntilReal(
  WidgetTester tester,
  bool Function() condition, {
  Duration ceiling = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(ceiling);
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 20));
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
