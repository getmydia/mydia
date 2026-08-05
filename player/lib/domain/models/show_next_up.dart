import 'media_file.dart';
import 'progress.dart';

/// Why this episode was chosen, as reported by the server.
///
/// `unknown` exists so a server that grows a fifth state does not break an
/// older client: the UI falls back to a generic label rather than throwing.
enum NextUpState { continueWatching, next, start, unknown }

NextUpState nextUpStateFromString(String? raw) {
  switch (raw) {
    case 'continue':
      return NextUpState.continueWatching;
    case 'next':
      return NextUpState.next;
    case 'start':
      return NextUpState.start;
    default:
      return NextUpState.unknown;
  }
}

class NextUpEpisode {
  final String id;
  final int seasonNumber;
  final int episodeNumber;
  final String? title;

  /// Provider metadata, in minutes. The episodes table has no runtime column;
  /// this is resolved from embedded metadata and is frequently null.
  final int? runtimeMinutes;

  final List<MediaFile> files;
  final Progress? progress;

  const NextUpEpisode({
    required this.id,
    required this.seasonNumber,
    required this.episodeNumber,
    this.title,
    this.runtimeMinutes,
    this.files = const [],
    this.progress,
  });

  factory NextUpEpisode.fromJson(Map<String, dynamic> json) {
    return NextUpEpisode(
      id: json['id'].toString(),
      seasonNumber: json['seasonNumber'] as int,
      episodeNumber: json['episodeNumber'] as int,
      title: json['title'] as String?,
      runtimeMinutes: json['runtime'] as int?,
      files: (json['files'] as List<dynamic>?)
              ?.map((e) => MediaFile.fromJson(e as Map<String, dynamic>))
              .toList() ??
          const [],
      progress: json['progress'] != null
          ? Progress.fromJson(json['progress'] as Map<String, dynamic>)
          : null,
    );
  }

  String get episodeCode => 'S${seasonNumber.toString().padLeft(2, '0')}'
      'E${episodeNumber.toString().padLeft(2, '0')}';
}

class ShowNextUp {
  final NextUpEpisode episode;
  final NextUpState state;

  const ShowNextUp({required this.episode, required this.state});

  factory ShowNextUp.fromJson(Map<String, dynamic> json) {
    return ShowNextUp(
      state: nextUpStateFromString(json['progressState'] as String?),
      episode: NextUpEpisode.fromJson(json['episode'] as Map<String, dynamic>),
    );
  }
}
