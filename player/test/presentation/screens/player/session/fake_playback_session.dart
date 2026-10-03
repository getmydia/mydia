import 'package:media_kit/media_kit.dart' show Player;
import 'package:player/core/playback/playback_controller.dart';
import 'package:player/core/playback/playback_plan.dart';
import 'package:player/core/playback/playback_transport.dart';
import 'package:player/core/playback/stream_urls.dart';
import 'package:player/core/player/progress_reporter.dart';
import 'package:player/core/player/stream_timeline.dart';
import 'package:player/domain/models/media_segment.dart';
import 'package:player/domain/models/subtitle_candidate.dart';
import 'package:player/domain/models/subtitle_search_outcome.dart';
import 'package:player/domain/models/subtitle_track.dart';
import 'package:player/presentation/screens/player/session/playback_session.dart';
import 'package:player/presentation/screens/player/session/playback_session_types.dart';

class FakeTransport implements PlaybackTransport {
  final opened = <PlaybackPlan>[];
  int ends = 0;

  @override
  String? get sessionId => null;
  @override
  bool get switching => false;
  @override
  ResolvedSource? sessionFile(String name) => null;

  @override
  Future<PlaybackSource> open(PlaybackPlan plan,
      {required String fileId,
      required Duration startAt,
      Duration? totalDuration,
      void Function(String message)? onProgress}) async {
    opened.add(plan);
    return PlaybackSource(
      url: 'https://fake.test/v.mkv',
      headers: const {'X-Plex-Token': 'tok'},
      timeline: StreamTimeline(totalDuration: totalDuration),
      fullPlaylist: false,
      seekOnOpen: true,
    );
  }

  @override
  Future<PlaybackSource> replaceSource(PlaybackPlan plan,
          {required String fileId,
          required Duration realPosition,
          Duration? totalDuration,
          required Future<Stream<Duration>> Function(PlaybackSource source)
              attach,
          void Function(String message)? onProgress}) =>
      throw UnimplementedError();

  @override
  Future<void> endSession() async => ends++;
}

class FakeProgress implements ProgressReporter {
  @override
  StreamTimeline timeline = StreamTimeline.zero;
  final starts = <(String, String)>[];
  final saves = <(String, String)>[];

  @override
  void start(Player player,
          {required String mediaType, required String mediaId}) =>
      starts.add((mediaType, mediaId));

  @override
  Future<void> save(Player player,
          {required String mediaType, required String mediaId}) async =>
      saves.add((mediaType, mediaId));

  @override
  bool isWatched(Player player) => false;
  @override
  void stopSync() {}
  @override
  void dispose() {}
}

class FakePlaybackSession implements PlaybackSession {
  final transport = FakeTransport();
  final progress = FakeProgress();
  int prepared = 0;

  @override
  Set<PlaybackFeature> get features => const {};

  @override
  Future<CandidatesFetch> candidates(CandidateScope scope) async => (
        offer: const PlaybackOffer(
          fileId: 'part-1',
          candidates: [
            CandidateStrategy(
                strategy: 'DIRECT_PLAY', mime: 'video/x-matroska'),
          ],
          durationSeconds: 90,
        ),
        serverRejected: false,
      );

  @override
  Future<PlaybackDetail?> detail() async => const PlaybackDetail();
  @override
  Future<List<MediaSegment>?> segments() async => null;
  @override
  Future<FetchedSubtitlePreference?> subtitlePreference() async => null;
  @override
  Future<Map<String, int>?> subtitleOffsets() async => null;
  @override
  Future<List<PlaybackEpisode>?> seasonEpisodes(int seasonNumber) async => null;
  @override
  Future<SubtitleSearchOutcome> searchSubtitles(List<String> languages) async =>
      const SubtitleSearchOutcome(results: [], providers: []);
  @override
  Future<SubtitleTrack> downloadSubtitle(SubtitleCandidate candidate) =>
      throw const SubtitleActionException('Not here.');
  @override
  Future<String?> subtitleContent(String trackId) async => null;
  @override
  bool get canWrite => false;
  @override
  Future<WriteOutcome> saveSubtitleOffset(
          {required String trackRef, required int offsetMs}) async =>
      WriteOutcome.unavailable;
  @override
  Future<List<String>?> rememberAudioLanguage(String language) async => null;
  @override
  Future<void> writeSubtitlePreference(
      {required String fileId, required SubtitleTrack? resolved}) async {}

  @override
  Future<ProgressReporter> openProgress() async => progress;

  @override
  Future<StreamingPreparation> prepareStreaming({
    required Object owner,
    required void Function(String message) onProgress,
    required bool Function() isCurrent,
  }) async {
    prepared++;
    return StreamingReady(StreamingSetup(
      memoryKey: 'source:fake',
      progress: progress,
      createTransport: ({required bool relayed}) => transport,
    ));
  }
}
