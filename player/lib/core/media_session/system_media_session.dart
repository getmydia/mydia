import '../remote/remote_control_intent.dart';
import 'media_session_state.dart';

/// The OS "now playing" surface: MPRIS on Linux, and in PR 2 SMTC, Now
/// Playing and MediaSession elsewhere. A thin mirror: it reflects state and
/// forwards commands, and never owns playback.
abstract class SystemMediaSession {
  /// OS button presses, already translated into app intents.
  Stream<RemoteControlIntent> get commands;

  /// Requests to bring the app window forward.
  Stream<void> get raiseRequests;

  Future<void> update(MediaSessionState state);

  Future<void> dispose();
}

/// Used where no OS session exists, and whenever connecting to one failed.
class NoopMediaSession implements SystemMediaSession {
  @override
  Stream<RemoteControlIntent> get commands => const Stream.empty();

  @override
  Stream<void> get raiseRequests => const Stream.empty();

  @override
  Future<void> update(MediaSessionState state) async {}

  @override
  Future<void> dispose() async {}
}
