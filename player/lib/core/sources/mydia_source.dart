/// The Mydia login `AuthService` already holds, as a [MediaSource].
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/download_option.dart';
import '../../domain/models/download_plan.dart';
import '../../domain/sources/item.dart';
import '../../domain/sources/library.dart';
import '../../domain/sources/source_error.dart';
import '../auth/auth_status.dart';
import '../downloads/download_job_service.dart';
import 'capabilities.dart';
import 'media_source.dart';
import 'mydia/mydia_guest_source.dart';
import 'mydia/mydia_transcode_job.dart';
import 'source.dart';

class MydiaSource extends MediaSource implements Downloadable {
  MydiaSource({required this.source, required this.auth, required this.jobs});

  @override
  final Source source;

  final AsyncValue<AuthStatus> auth;

  /// The home job service, or null while signed out or still connecting.
  final DownloadJobService? Function() jobs;

  /// Only downloads go through this layer so far. Mydia's screens predate it
  /// and consult nothing else here; capabilities are declared as its
  /// controllers move behind [MediaSource]. Artwork is the one other call
  /// this stub answers.
  @override
  Set<SourceCapability> get capabilities =>
      const {SourceCapability.downloadable};

  /// Reachable Mydia reports [SourceConnectionStatus.remote]: the existing
  /// connection layer does not distinguish a LAN route from a remote one.
  @override
  SourceConnectionStatus get connection => switch (auth) {
        AsyncData(value: AuthStatus.authenticated) =>
          SourceConnectionStatus.remote,
        AsyncData() => SourceConnectionStatus.unreachable,
        AsyncError() => SourceConnectionStatus.unreachable,
        _ => SourceConnectionStatus.connecting,
      };

  late final ValueNotifier<SourceConnectionStatus> _status =
      ValueNotifier(connection);

  @override
  ValueListenable<SourceConnectionStatus> get statusListenable => _status;

  @override
  T? as<T extends Object>() => this is T ? this as T : null;

  DownloadJobService _service() =>
      jobs() ?? (throw const SourceException.unreachable());

  @override
  Future<List<DownloadOption>> downloadOptions(ItemRef ref) async =>
      (await _service().getOptions(mydiaContentType(ref.kind), ref.externalId))
          .options;

  @override
  Future<DownloadPlan> resolve(ItemRef ref, String optionId) async {
    final service = _service();
    return MydiaTranscodeJob(
      jobs: service,
      contentType: mydiaContentType(ref.kind),
      id: ref.externalId,
      resolution: optionId,
      // HTTP signs the URL with the media token; p2p points at the local
      // proxy. Either way the URL carries everything and needs no headers.
      fileFor: (jobId) async => DirectFile(
          url: await service.getDownloadUrl(jobId), extension: 'mp4'),
    );
  }

  // Mydia's screens predate this interface and stay on their own
  // controllers. Moving them behind it is a later, opt-in migration.
  static Never _ownScreens() => throw UnsupportedError(
      'Mydia browses through its own screens, not MediaSource');

  @override
  Future<List<Library>> libraries() async => _ownScreens();

  @override
  Future<Page<ItemSummary>> browse(LibraryRef library, BrowseQuery query,
          {Cursor? cursor}) async =>
      _ownScreens();

  @override
  Future<ItemDetail> item(ItemRef ref) async => _ownScreens();

  @override
  Future<Page<ItemSummary>> children(ItemRef parent, {Cursor? cursor}) async =>
      _ownScreens();

  @override
  Future<ArtworkRequest?> artwork(ArtworkRef art, {required int width}) async =>
      absoluteArtworkRequest(id, art, width);

  @override
  void dispose() => _status.dispose();
}
