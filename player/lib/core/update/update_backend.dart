import '../../domain/models/available_update.dart';
import 'update_track.dart';

/// What the settings "Check for updates" row should say and do.
enum ManualCheckBehaviour {
  /// The press looks for an update and reports what it found.
  checksOnly,

  /// The press checks and installs in one action. The Flatpak portal has no
  /// on-demand check, but its Update call pulls fresh, so this is the honest
  /// shape there.
  checksAndInstalls,

  /// The press opens Sparkle's own dialog, which owns the rest.
  delegatesToSparkle,

  /// The row is not shown.
  unavailable,
}

/// The result of the user asking for an update.
sealed class UpdateOutcome {
  const UpdateOutcome();
}

final class UpdateInstalled extends UpdateOutcome {
  /// True when the running process is still on the old build.
  final bool restartRequired;

  const UpdateInstalled({this.restartRequired = false});
}

final class AlreadyUpToDate extends UpdateOutcome {
  const AlreadyUpToDate();
}

/// The platform refused in a way nothing in-app can resolve.
final class UpdateUnsupported extends UpdateOutcome {
  final String reason;

  const UpdateUnsupported(this.reason);
}

final class UpdateFailed extends UpdateOutcome {
  final String message;

  const UpdateFailed(this.message);
}

/// The backend handed the user off somewhere else, such as Sparkle's dialog
/// or the browser fallback, and owes no further reporting.
final class UpdateDeferred extends UpdateOutcome {
  const UpdateDeferred();
}

/// What happened when the user chose a track.
sealed class TrackSwitchOutcome {
  const TrackSwitchOutcome();
}

/// The backend now follows the chosen track.
final class TrackSwitchApplied extends TrackSwitchOutcome {
  const TrackSwitchApplied();
}

/// Only the host or the store can make this switch, and the user has been
/// told how. Flatpak branches and TestFlight groups both land here: no code
/// inside the sandbox or the app bundle can move an install between them.
final class TrackSwitchDeferred extends TrackSwitchOutcome {
  final String instructions;
  final String? url;

  const TrackSwitchDeferred({required this.instructions, this.url});
}

/// The backend cannot offer this track at all.
final class TrackSwitchUnsupported extends TrackSwitchOutcome {
  final String reason;

  const TrackSwitchUnsupported(this.reason);
}

/// How this installation learns about, and installs, its own updates.
///
/// Checking and applying live behind one interface because on Flatpak they
/// are the same portal call. Keeping them apart would mean the state object
/// carrying two fields for one concept.
abstract interface class UpdateBackend {
  /// Opens whatever the backend needs before it can report anything. Called
  /// once, and must not throw: a backend that cannot start reports
  /// [canUpdateInPlace] false and explains itself from [requestUpdate].
  Future<void> start();

  /// Emits whenever availability changes. Null means nothing is available.
  Stream<AvailableUpdate?> get availability;

  /// Look for an update without installing anything. A documented no-op on
  /// backends whose platform owns the polling.
  Future<void> refresh({bool force = false});

  /// The user pressed the update affordance. Must not throw: a backend that
  /// fails reports that through [UpdateFailed] or [UpdateUnsupported]
  /// instead, mirroring [start]. [UpdateNotifier.requestUpdate] awaits this
  /// with no try/catch of its own, relying on the contract to hold.
  Future<UpdateOutcome> requestUpdate({
    void Function(double progress)? onProgress,
  });

  ManualCheckBehaviour get manualCheck;

  /// Whether the update affordance can be offered at all.
  bool get canUpdateInPlace;

  /// The tracks this installation can be pointed at.
  ///
  /// A track a platform has never published is absent, so a picker built from
  /// this cannot offer a choice that resolves to nothing.
  Set<UpdateTrack> get availableTracks;

  /// The track this installation currently follows.
  UpdateTrack get currentTrack;

  /// The user chose a track. Must not throw, for the same reason
  /// [requestUpdate] must not: the caller has no try/catch of its own.
  ///
  /// Selecting a lower track never downgrades anything. The installed build
  /// stays until the chosen track publishes something newer, which is what
  /// Sparkle has always done on macOS and what Android's refusal to install
  /// an older build forces everywhere else.
  Future<TrackSwitchOutcome> selectTrack(UpdateTrack track);

  Future<void> dispose();
}
