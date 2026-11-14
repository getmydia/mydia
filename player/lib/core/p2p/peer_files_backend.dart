/// The files of a library a paired player lends, read through it.
library;

import 'package:flutter/foundation.dart';

import '../sources/files/backend/file_system_backend.dart';
import 'media_proxy.dart';
import 'media_route.dart';
import 'p2p_range_stream.dart';
import 'peer_files_transport.dart';

/// A [FileSystemBackend] over another member's files account.
///
/// The viewer browses the copy of the host's index it keeps, so nothing
/// here lists or stats: only [playable] reaches the host, as a `peerfile:`
/// byte stream through the local proxy. [path] arguments are the host's own
/// backend paths, which is what the replicated index holds and what the
/// host authorizes.
class PeerFilesBackend implements FileSystemBackend {
  PeerFilesBackend({
    required this.nodeId,
    required this.hostAccountId,
    required MediaProxy proxy,
    required PeerFilesTransport transport,
    required bool Function(String nodeId) isConnected,
  })  : _proxy = proxy,
        _transport = transport,
        _isConnected = isConnected;

  final String nodeId;

  /// The account's id on the host, which names it in every read.
  final String hostAccountId;
  final MediaProxy _proxy;
  final PeerFilesTransport _transport;
  final bool Function(String nodeId) _isConnected;

  /// The proxy target for this host, shared by all of its accounts.
  String get target =>
      'peer_${nodeId.substring(0, nodeId.length < 12 ? nodeId.length : 12)}';

  String get _sessionId => '${MediaRoutes.peerFileSessionPrefix}$hostAccountId';

  /// One owner per proxy target for the life of the process. A playback
  /// keeps its URL after the source that handed it out is rebuilt (each new
  /// copy of the host's index rebuilds it), so no source may let the target
  /// go; holding it under a fixed owner keeps it served and held once.
  static final _owners = <String, Object>{};

  @override
  Future<PlayableFile> playable(String path) async {
    final token = MediaRoutes.peerFileToken(path);
    // One byte first, so a host that is gone or a file that is gone fails
    // here, where it can be named, rather than inside the video pipeline.
    final P2pRangeStream probe;
    try {
      probe = await _transport.openRangeStream(
        peer: nodeId,
        sessionId: _sessionId,
        path: token,
        rangeStart: 0,
        rangeEnd: 0,
      );
    } catch (e) {
      debugPrint('[PeerFilesBackend] Could not reach $nodeId: $e');
      throw const BackendUnreachable('peer did not answer');
    }
    final status = probe.header.status;
    probe.cancel();
    switch (status) {
      case >= 200 && < 300:
        break;
      case 404:
        throw const BackendNotFound('not on the peer');
      case 403:
        throw const BackendUnauthorized('peer refused the read');
      default:
        throw BackendUnreachable('peer answered $status', status);
    }
    try {
      await _proxy.start(
        owner: _owners.putIfAbsent(target, Object.new),
        targetPeer: nodeId,
        target: target,
      );
    } catch (e) {
      debugPrint('[PeerFilesBackend] Local proxy did not start: $e');
      throw const BackendUnreachable('local proxy did not start');
    }
    return PlayableFile(
      url: MediaRoutes.peerFile(
          _proxy.targetBaseUrl(target), hostAccountId, path),
    );
  }

  @override
  Future<List<FileEntry>> list(String dir) async =>
      throw const BackendUnreachable('read-only peer library');

  @override
  Future<FileEntry?> stat(String path) async =>
      throw const BackendUnreachable('read-only peer library');

  /// Reachable while the host is connected. A host that is not may still
  /// answer a play, which dials it.
  @override
  Future<void> probe() async {
    if (!_isConnected(nodeId)) {
      throw const BackendUnreachable('peer not connected');
    }
  }
}
