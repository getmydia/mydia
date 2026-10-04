library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/sources/lock/source_lock_controller.dart';
import '../../../core/sources/source.dart';
import '../../../core/sources/sources_providers.dart';
import '../../../domain/sources/item.dart';
import '../player/player_screen.dart';
import '../player/session/playback_session.dart';
import '../player/session/source_playback_sessions.dart';

/// What `/s/:sourceId/player/:itemId` carries in its query.
class SourcePlayerParams {
  const SourcePlayerParams({
    required this.kind,
    required this.fileId,
    this.title,
    this.showId,
    this.seasonNumber,
    this.resumeSeconds,
  });

  factory SourcePlayerParams.fromUri(Uri uri) {
    final q = uri.queryParameters;
    return SourcePlayerParams(
      kind: ItemKind.values.asNameMap()[q['kind']] ?? ItemKind.movie,
      fileId: q['fileId'] ?? '',
      title: q['title'],
      showId: q['showId'],
      seasonNumber: int.tryParse(q['seasonNumber'] ?? ''),
      resumeSeconds: int.tryParse(q['resume'] ?? ''),
    );
  }

  final ItemKind kind;
  final String fileId;
  final String? title;
  final String? showId;
  final int? seasonNumber;
  final int? resumeSeconds;

  /// The player screen's vocabulary: episodes are episodes, anything else
  /// plays as a movie (no season list, no up-next).
  String get mediaType => kind == ItemKind.episode ? 'episode' : 'movie';
}

/// Keyed by the whole location: a second item reached in place must build a
/// fresh route state, and with it a fresh session.
Widget sourcePlayerRouteBuilder(BuildContext context, GoRouterState state) =>
    SourcePlayerRoute(
      key: ValueKey(state.uri.toString()),
      sourceId: SourceId(state.pathParameters['sourceId']!),
      itemId: state.pathParameters['itemId']!,
      uri: state.uri,
    );

class SourcePlayerRoute extends ConsumerStatefulWidget {
  const SourcePlayerRoute({
    super.key,
    required this.sourceId,
    required this.itemId,
    required this.uri,
  });

  final SourceId sourceId;
  final String itemId;
  final Uri uri;

  @override
  ConsumerState<SourcePlayerRoute> createState() => _SourcePlayerRouteState();
}

class _SourcePlayerRouteState extends ConsumerState<SourcePlayerRoute> {
  late final SourcePlayerParams _params =
      SourcePlayerParams.fromUri(widget.uri);

  /// Built once: the player screen reads its session in `initState`.
  late final PlaybackSession? _session = () {
    // A location with no file id cannot name a stream to open.
    if (_params.fileId.isEmpty) return null;
    final source = ref.read(mediaSourceProvider(widget.sourceId));
    if (source == null) return null;
    return playbackSessionFor(
      source,
      ItemRef(
        sourceId: widget.sourceId,
        kind: _params.kind,
        externalId: widget.itemId,
      ),
      _params.fileId,
    );
  }();

  void Function()? _releaseLock;

  @override
  void initState() {
    super.initState();
    // Playback from a locked or hidden source keeps the app unlocked until
    // it stops, so a background relock never cuts the stream.
    if (ref.read(sourceLocksProvider).containsKey(widget.sourceId)) {
      _releaseLock = ref.read(sourceLockProvider.notifier).hold();
    }
  }

  @override
  void dispose() {
    // Releasing can lock, which changes provider state: not while the tree
    // is being finalized.
    final release = _releaseLock;
    if (release != null) {
      final binding = WidgetsBinding.instance;
      binding.addPostFrameCallback((_) => release());
      binding.scheduleFrame();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    if (session == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(
          key: Key('source-player-unavailable'),
          child: Text('This server is not available to play from.'),
        ),
      );
    }
    return PlayerScreen(
      mediaType: _params.mediaType,
      mediaId: widget.itemId,
      fileId: _params.fileId,
      title: _params.title,
      showId: _params.showId,
      seasonNumber: _params.seasonNumber,
      resumeSeconds: _params.resumeSeconds,
      session: session,
    );
  }
}
