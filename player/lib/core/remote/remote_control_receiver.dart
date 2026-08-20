import 'package:flutter/foundation.dart' show debugPrint;

import '../../native/lib.dart';
import 'remote_control_intent.dart';
import 'remote_roster.dart';

/// Current playback state, or null when no player is mounted.
typedef PlaybackSnapshotSource = FlutterPlaybackSnapshot? Function();

/// Handles control commands arriving from another player.
///
/// Knows nothing about video. It checks the roster, answers the two commands
/// that are pure queries, and turns everything else into an intent for the app
/// to carry out. That is what makes it testable without a playback pipeline.
///
/// There is deliberately no notion of "a session I was told to start". A
/// session begun locally and one pushed from a phone are the same thing, and
/// tracking the difference would break taking over a locally started session,
/// which is the main point of the feature.
class RemoteControlReceiver {
  final RemoteRoster _roster;
  final String _targetName;
  final PlaybackSnapshotSource _snapshotSource;
  final void Function(RemoteControlIntent) _onIntent;
  final Future<void> Function(String requestId, FlutterRemoteControlResponse)
      _respond;

  RemoteControlReceiver({
    required RemoteRoster roster,
    required String targetName,
    required PlaybackSnapshotSource snapshotSource,
    required void Function(RemoteControlIntent) onIntent,
    required Future<void> Function(String, FlutterRemoteControlResponse)
        respond,
  })  : _roster = roster,
        _targetName = targetName,
        _snapshotSource = snapshotSource,
        _onIntent = onIntent,
        _respond = respond;

  Future<void> handle(FlutterInboundControlRequest inbound) async {
    // The peer node ID is authenticated by iroh during the handshake, so this
    // membership test is the entire access check. Nothing in the payload is
    // trusted for identity.
    if (!await _roster.allows(inbound.peer)) {
      debugPrint('[RemoteControl] refused ${inbound.peer}');
      await _respond(
        inbound.requestId,
        const FlutterRemoteControlResponse_NotAuthorized(),
      );
      return;
    }

    final request = inbound.request;

    if (request is FlutterRemoteControlRequest_Hello) {
      await _respond(
        inbound.requestId,
        FlutterRemoteControlResponse_Welcome(
          targetName: _targetName,
          protocolVersion: request.protocolVersion,
          capabilities: _capabilities(),
        ),
      );
      return;
    }

    if (request is FlutterRemoteControlRequest_GetState) {
      final snapshot = _snapshotSource();
      await _respond(
        inbound.requestId,
        snapshot == null
            ? const FlutterRemoteControlResponse_NotPlaying()
            : FlutterRemoteControlResponse_State(snapshot),
      );
      return;
    }

    final intent = RemoteControlIntent.fromRequest(request);
    if (intent == null) {
      await _respond(
        inbound.requestId,
        const FlutterRemoteControlResponse_Unsupported(),
      );
      return;
    }

    // LoadContent is what starts playback, so it is the one intent that is
    // valid with nothing mounted. Everything else needs a player to act on.
    if (intent is! LoadContentIntent && _snapshotSource() == null) {
      await _respond(
        inbound.requestId,
        const FlutterRemoteControlResponse_NotPlaying(),
      );
      return;
    }

    _onIntent(intent);
    await _respond(
        inbound.requestId, const FlutterRemoteControlResponse_Accepted());
  }

  /// What this build can do. Reported from the live snapshot when there is one
  /// so a target that cannot change volume on its platform says so, rather
  /// than accepting a command that does nothing.
  FlutterTargetCapabilities _capabilities() {
    final snapshot = _snapshotSource();
    return snapshot?.capabilities ??
        const FlutterTargetCapabilities(
          volume: true,
          trackSelection: true,
          nextPrevious: true,
        );
  }
}
