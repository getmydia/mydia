/// Playing a file from a files library: mpv opens the file itself (a path on
/// this device, or a WebDAV URL with its auth header), so there is no
/// transcode, no cast and no server to report to. Progress is kept locally.
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../../../core/playback/loading_step.dart';
import '../../../../core/playback/playback_plan.dart';
import '../../../../core/playback/simple_playback_transport.dart';
import '../../../../core/player/local_progress_reporter.dart';
import '../../../../core/player/progress_reporter.dart';
import '../../../../core/sources/files/backend/file_system_backend.dart';
import '../../../../core/sources/files/files_media_source.dart';
import '../../../../core/sources/files/files_queries.dart';
import '../../../../core/sources/files/index/index_records.dart';
import '../../../../domain/sources/item.dart';
import '../../../../l10n/l10n.dart';
import 'playback_problem.dart';
import 'playback_session_types.dart';
import 'source_playback_session.dart';

class FilesPlaybackSession extends SourcePlaybackSession {
  FilesPlaybackSession({
    required FilesMediaSource source,
    required super.item,
    required super.fileId,
    http.Client? client,
  })  : _files = source,
        _client = client,
        super(source: source);

  final FilesMediaSource _files;
  final http.Client? _client;

  /// Always: an unreachable files source (one folder of several unplugged,
  /// a share that is down) is no reason to refuse every file.
  /// [prepareStreaming] checks the chosen file itself and says "Folder
  /// unavailable" when that one is gone.
  @override
  bool get reachable => true;

  @override
  List<CandidateStrategy> candidatesFor(MediaVersion version) => [
        CandidateStrategy(
          strategy: 'DIRECT_PLAY',
          mime: containerMime(version.container),
          videoCodec: version.videoCodec,
        ),
      ];

  /// [path] is a backend path. A local file is read; a WebDAV one is fetched
  /// with the backend's auth headers.
  @override
  Future<String> fetchText(String path) async {
    final playable = await _files.backend.playable(path);
    final uri = Uri.tryParse(playable.url);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      return File(playable.url).readAsString();
    }
    final client = _client ?? http.Client();
    try {
      final response = await client.get(uri, headers: playable.headers);
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode}', uri: uri);
      }
      // `body` reads a reply with no declared charset as Latin-1, which
      // garbles UTF-8 subtitles, and that is what servers send them as.
      return _declaresCharset(response.headers['content-type'])
          ? response.body
          : utf8.decode(response.bodyBytes, allowMalformed: true);
    } finally {
      if (_client == null) client.close();
    }
  }

  static final _charset = RegExp(r';\s*charset\s*=', caseSensitive: false);

  static bool _declaresCharset(String? contentType) =>
      contentType != null && _charset.hasMatch(contentType);

  @override
  ProgressReporter createProgress() => LocalProgressReporter(
        store: _files.progressStore,
        item: item,
        currentItem: () => _files.currentRef(item, fileId),
        resumeMinSeconds: kFilesResumeMinSeconds,
        watchedFraction: kFilesWatchedFraction,
        syncStore: _files.syncStore,
        syncKeyFor: _files.syncKeyFor,
        onSyncWrite: _files.onSyncMutation,
        // The identity playback writes under, which a match made during
        // playback changes.
        onChanged: () =>
            _files.invalidateWatchedFor(_files.currentRef(item, fileId)),
      );

  @override
  StreamResolver createResolver(ItemDetail detail, MediaVersion version) =>
      FilesStreamResolver(source: _files);

  @override
  StreamResolver createReceiverResolver(
    ItemDetail detail,
    MediaVersion version, {
    String? burnSubtitleStreamId,
  }) =>
      createResolver(detail, version);

  /// Checks the file is still there before opening it, so a missing drive or
  /// share reads as such instead of as an mpv failure.
  @override
  Future<StreamingPreparation> prepareStreaming({
    required Object owner,
    required void Function(LoadingStep step) onProgress,
    required bool Function() isCurrent,
  }) async {
    try {
      final (_, version) = await pickedVersion();
      if (version != null && !await _fileIsThere(_files, version.id)) {
        return StreamingUnavailable(PlaybackProblem.fromText(
            currentAppLocalizations().filesFolderUnavailable));
      }
    } catch (_) {
      // Not a file problem; the base class words it.
    }
    return super.prepareStreaming(
        owner: owner, onProgress: onProgress, isCurrent: isCurrent);
  }
}

/// The backend path of the file with [fileKey], or null when the index no
/// longer holds it or its root.
String? _backendPathOf(FilesMediaSource source, String fileKey) {
  final IndexedFile? file = source.index.files()[fileKey];
  if (file == null) return null;
  final root =
      source.index.roots().where((r) => r.id == file.rootId).firstOrNull;
  return root == null ? null : filesBackendPath(root, file.path);
}

Future<bool> _fileIsThere(FilesMediaSource source, String fileKey) async {
  final path = _backendPathOf(source, fileKey);
  if (path == null) return false;
  try {
    return await source.backend.stat(path) != null;
  } on BackendFailure {
    return false;
  }
}

class FilesStreamResolver implements StreamResolver {
  FilesStreamResolver({required this.source});

  final FilesMediaSource source;

  @override
  Future<ResolvedStream> resolve(
    PlaybackPlan plan, {
    required String fileId,
    required Duration startAt,
  }) async {
    final path = _backendPathOf(source, fileId);
    if (path == null) {
      throw const PlaybackIssueException(PlaybackIssue.noPlayableFile);
    }
    final playable = await source.backend.playable(path);
    return ResolvedStream(url: playable.url, headers: playable.headers);
  }

  /// Nothing was started on a server.
  @override
  Future<void> end(String sessionId) async {}
}
