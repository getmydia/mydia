import 'package:flutter/foundation.dart' show immutable;

/// Where this device stands in publishing its iroh node ID to the server.
///
/// A device the server has no node ID for is filtered out of every
/// `RemoteRoster`, so it is invisible to and unreachable from every other
/// device on the account. That failure used to be entirely silent, which is
/// what let it persist unnoticed; this type exists so the settings screen can
/// say which step is stuck.
///
/// The settings row words each status in the viewer's language
/// (`AppFormatters.registrationStatusText`), so a status carries no prose.
@immutable
sealed class RegistrationStatus {
  const RegistrationStatus();
}

/// This device has opted out of being controlled, so nothing is published.
@immutable
class RegistrationIdle extends RegistrationStatus {
  const RegistrationIdle();
}

/// What registration is waiting for.
enum RegistrationDependency {
  remoteControlSetting,
  deviceOnline,
  serverConnection,
}

/// A precondition has not arrived yet. Normal for the first seconds of a
/// launch, and not an error.
@immutable
class RegistrationWaiting extends RegistrationStatus {
  final RegistrationDependency dependency;

  const RegistrationWaiting(this.dependency);
}

/// A registration attempt is in flight. [attempt] counts from 1.
@immutable
class RegistrationInFlight extends RegistrationStatus {
  final String nodeId;
  final int attempt;

  const RegistrationInFlight(this.nodeId, this.attempt);
}

/// The server has confirmed it holds [nodeId] for this device.
@immutable
class RegistrationSucceeded extends RegistrationStatus {
  final String nodeId;
  final DateTime at;

  const RegistrationSucceeded(this.nodeId, this.at);
}

/// The last attempt failed. [nextRetryAt] is null when nothing is scheduled.
@immutable
class RegistrationFailed extends RegistrationStatus {
  final String reason;
  final int attempts;
  final DateTime? nextRetryAt;

  const RegistrationFailed(this.reason, this.attempts, this.nextRetryAt);
}

/// The status a single row should show for several instances: the one that
/// most needs attention, `Failed` > `Waiting` > `InFlight` > `Succeeded` >
/// `Idle`. Idle with nothing to summarise.
RegistrationStatus worstRegistrationStatus(
  Iterable<RegistrationStatus> statuses,
) {
  int rank(RegistrationStatus s) => switch (s) {
        RegistrationFailed() => 4,
        RegistrationWaiting() => 3,
        RegistrationInFlight() => 2,
        RegistrationSucceeded() => 1,
        RegistrationIdle() => 0,
      };
  RegistrationStatus worst = const RegistrationIdle();
  var worstRank = -1;
  for (final s in statuses) {
    if (rank(s) > worstRank) {
      worst = s;
      worstRank = rank(s);
    }
  }
  return worst;
}
