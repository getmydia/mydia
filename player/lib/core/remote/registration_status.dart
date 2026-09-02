import 'package:flutter/foundation.dart' show immutable;

/// Where this device stands in publishing its iroh node ID to the server.
///
/// A device the server has no node ID for is filtered out of every
/// `RemoteRoster`, so it is invisible to and unreachable from every other
/// device on the account. That failure used to be entirely silent, which is
/// what let it persist unnoticed; this type exists so the settings screen can
/// say which step is stuck.
@immutable
sealed class RegistrationStatus {
  const RegistrationStatus();

  /// One line of user-facing prose. Lives here rather than in the widget so
  /// the wording is covered by a unit test instead of a widget test.
  String describe();
}

/// This device has opted out of being controlled, so nothing is published.
@immutable
class RegistrationIdle extends RegistrationStatus {
  const RegistrationIdle();

  @override
  String describe() => 'Not advertising this device';
}

/// A precondition has not arrived yet. Normal for the first seconds of a
/// launch, and not an error.
@immutable
class RegistrationWaiting extends RegistrationStatus {
  final String dependency;

  const RegistrationWaiting(this.dependency);

  @override
  String describe() => 'Waiting for $dependency';
}

/// A registration attempt is in flight. [attempt] counts from 1.
@immutable
class RegistrationInFlight extends RegistrationStatus {
  final String nodeId;
  final int attempt;

  const RegistrationInFlight(this.nodeId, this.attempt);

  @override
  String describe() => 'Registering with the server (attempt $attempt)';
}

/// The server has confirmed it holds [nodeId] for this device.
@immutable
class RegistrationSucceeded extends RegistrationStatus {
  final String nodeId;
  final DateTime at;

  const RegistrationSucceeded(this.nodeId, this.at);

  @override
  String describe() => 'Discoverable by your other devices';
}

/// The last attempt failed. [nextRetryAt] is null when nothing is scheduled.
@immutable
class RegistrationFailed extends RegistrationStatus {
  final String reason;
  final int attempts;
  final DateTime? nextRetryAt;

  const RegistrationFailed(this.reason, this.attempts, this.nextRetryAt);

  @override
  String describe() => 'Not discoverable: $reason';
}
