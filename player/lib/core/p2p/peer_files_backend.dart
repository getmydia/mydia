/// The files of a library a paired player lends, read through it.
library;

import 'dart:convert';

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
    String? Function(String nodeId)? addressOf,
  })  : _proxy = proxy,
        _transport = transport,
        _isConnected = isConnected,
        _addressOf = addressOf;

  final String nodeId;

  /// The account's id on the host, which names it in every read.
  final String hostAccountId;
  final MediaProxy _proxy;
  final PeerFilesTransport _transport;
  final bool Function(String nodeId) _isConnected;

  /// The host's EndpointAddr JSON from the sync roster, null when the
  /// roster holds none.
  final String? Function(String nodeId)? _addressOf;

  /// The proxy target for [nodeId], shared by all of its accounts.
  static String targetFor(String nodeId) =>
      'peer_${nodeId.substring(0, nodeId.length < 12 ? nodeId.length : 12)}';

  String get target => targetFor(nodeId);

  String get _sessionId => '${MediaRoutes.peerFileSessionPrefix}$hostAccountId';

  /// One owner per host's proxy target, held while the host lends this
  /// device anything. A playback keeps its URL after the source that handed
  /// it out is rebuilt (each new copy of the host's index rebuilds it), so
  /// no source may let the target go; [releaseHost] does, once the host no
  /// longer lends.
  static final _owners = <String, Object>{};

  /// Lets go of [nodeId]'s proxy target, when one is held. Called once the
  /// host lends this device nothing (revoked, left, or its last account
  /// withdrawn), so targets do not pile up for the life of the process.
  /// [proxy] is read only when there is something to release.
  static Future<void> releaseHost(
      String nodeId, MediaProxy Function() proxy) async {
    final target = targetFor(nodeId);
    final owner = _owners.remove(target);
    if (owner == null) return;
    try {
      await proxy().stop(owner, target: target);
    } catch (e) {
      debugPrint('[PeerFilesBackend] Releasing $target failed: $e');
    }
  }

  @override
  Future<PlayableFile> playable(String path) async {
    // A source built from a record that names no host has nowhere to read.
    if (nodeId.isEmpty) throw const BackendUnreachable('no peer node id');
    // A read only waits for a connection; it never makes one. A host this
    // device is not connected to is dialed once, with the address its
    // roster entry holds, so a play can reach a host nothing else has.
    if (!_isConnected(nodeId)) await _dial();
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
      // 416 answers a one-byte probe of an empty file: it is there.
      case (>= 200 && < 300) || 416:
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

  /// Dials the host with its roster address, or by node ID alone when the
  /// roster holds none (a member can join without one), which discovery
  /// resolves. Skipping the dial would leave the probe waiting on a
  /// connection nothing started. Never throws: a dial that fails leaves the
  /// probe after it to fail, as unreachable.
  Future<void> _dial() async {
    final address = _addressOf?.call(nodeId) ??
        jsonEncode({'id': nodeId, 'addrs': <Object>[]});
    try {
      await _transport.dial(address);
    } catch (e) {
      debugPrint('[PeerFilesBackend] Dialing $nodeId failed: $e');
    }
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
    if (nodeId.isEmpty || !_isConnected(nodeId)) {
      throw const BackendUnreachable('peer not connected');
    }
  }
}
