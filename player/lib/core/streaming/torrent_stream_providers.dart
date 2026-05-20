import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../graphql/graphql_provider.dart';
import '../../domain/models/torrent_candidate.dart';
import 'torrent_stream_service.dart';

part 'torrent_stream_providers.g.dart';

@riverpod
Future<TorrentStreamService> torrentStreamService(Ref ref) async {
  final client = await ref.watch(asyncGraphqlClientProvider.future);
  return TorrentStreamService(client);
}

@riverpod
Future<List<TorrentCandidate>> torrentCandidates(
  Ref ref,
  String contentType,
  String id,
) async {
  final service = await ref.watch(torrentStreamServiceProvider.future);
  return await service.getCandidates(contentType, id);
}
