import 'dart:async';
import 'dart:math' show min;

import 'package:flutter/foundation.dart' show debugPrint;

import 'registration_status.dart';

/// Publishes [nodeId] to the server. Returns whether the server confirmed it.
/// Must not throw for an ordinary failure, but this service treats a throw as
/// a retryable failure anyway, because a transport can always surprise it.
typedef RegisterNode = Future<bool> Function(String nodeId);

/// Backoff schedule, capped at the last entry.
///
/// Registration is cheap and the consequence of not registering is total
/// invisibility, so the early steps are short. The cap keeps a server that is
/// down for hours from being hammered.
const _backoff = <Duration>[
  Duration(seconds: 2),
  Duration(seconds: 4),
  Duration(seconds: 8),
  Duration(seconds: 16),
  Duration(seconds: 32),
  Duration(seconds: 60),
];

/// Keeps the server's record of this device's iroh node ID current.
///
/// Registration used to be a startup event: one awaited chain in `app.dart`
/// with three silent early returns and no retry, so a single unlucky moment
/// during launch left the device undiscoverable for the whole session with no
/// visible symptom. This class treats it as an invariant instead. Inputs are
/// pushed in by [update] whenever they change, and the loop reconciles the
/// desired state (the server holds the current node ID) against the observed
/// one, retrying until they match.
class NodeRegistrationService {
  final RegisterNode _register;
  final DateTime Function() _now;
  final Future<void> Function(Duration) _delay;

  NodeRegistrationService({
    required RegisterNode register,
    DateTime Function()? now,
    Future<void> Function(Duration)? delay,
  })  : _register = register,
        _now = now ?? DateTime.now,
        _delay = delay ?? Future.delayed;

  RegistrationStatus _status = const RegistrationIdle();
  final _controller = StreamController<RegistrationStatus>.broadcast();

  bool _controllable = false;
  String? _desiredNodeId;
  bool _clientReady = false;

  /// The node ID the server is known to hold. Cleared implicitly by comparing
  /// against [_desiredNodeId], which is what makes a node ID change re-register.
  String? _registeredNodeId;

  /// Bumped by every [update] and [retryNow]. The loop compares it against the
  /// value it started with, so inputs changing mid-attempt abandon that attempt
  /// instead of letting a stale result overwrite fresher state.
  int _generation = 0;

  bool _running = false;

  /// Closing [_controller] only silences [_emit]'s output; it does not stop
  /// the reconcile loop itself. Without this flag, a disposed service whose
  /// loop is between attempts would re-read its still-unchanged inputs, see
  /// them unsatisfied, and start a fresh attempt that keeps calling
  /// [_register] and [_delay] for real, forever.
  bool _disposed = false;

  RegistrationStatus get status => _status;

  /// The current status, replayed to each new listener before any later
  /// update.
  ///
  /// Deliberately not `async*`. A generator body does not start until the
  /// consumer listens and then advances over several microtasks, so a
  /// caller that listens and then synchronously calls [update] loses every
  /// event emitted before `yield*` managed to attach. `onListen` fires
  /// synchronously from `listen()`, so the upstream subscription is in
  /// place before any caller can emit.
  Stream<RegistrationStatus> get statuses {
    late final StreamController<RegistrationStatus> out;
    StreamSubscription<RegistrationStatus>? subscription;

    out = StreamController<RegistrationStatus>(
      onListen: () {
        subscription = _controller.stream.listen(
          out.add,
          onError: out.addError,
          onDone: out.close,
        );
        out.add(_status);
      },
      onCancel: () => subscription?.cancel(),
    );

    return out.stream;
  }

  /// Feeds the loop the latest view of its three inputs. Safe to call on every
  /// rebuild: identical inputs that are already satisfied do no work.
  void update({
    required bool controllable,
    required String? nodeId,
    required bool clientReady,
  }) {
    if (_disposed) return;
    _controllable = controllable;
    _desiredNodeId = nodeId;
    _clientReady = clientReady;
    _generation += 1;
    unawaited(_reconcile());
  }

  /// Abandons any pending backoff and reconciles immediately. Wired to the
  /// retry action in settings.
  void retryNow() {
    if (_disposed) return;
    _generation += 1;
    unawaited(_reconcile());
  }

  Future<void> _reconcile() async {
    if (_running) return;
    _running = true;
    try {
      while (true) {
        if (_disposed) return;

        final generation = _generation;

        if (!_controllable) {
          _emit(const RegistrationIdle());
          return;
        }

        final nodeId = _desiredNodeId;
        if (nodeId == null) {
          _emit(const RegistrationWaiting('this device to come online'));
          return;
        }

        if (!_clientReady) {
          _emit(const RegistrationWaiting('a server connection'));
          return;
        }

        if (_registeredNodeId == nodeId) return;

        final restart = await _attemptUntilSuccess(nodeId, generation);
        if (!restart) return;
      }
    } finally {
      _running = false;
    }
  }

  /// Retries [nodeId] until the server confirms it. Returns true when the
  /// caller should re-read its inputs and start over, because [_generation]
  /// moved while this was working.
  Future<bool> _attemptUntilSuccess(String nodeId, int generation) async {
    var attempt = 0;

    while (true) {
      if (generation != _generation) return true;

      attempt += 1;
      _emit(RegistrationInFlight(nodeId, attempt));

      var confirmed = false;
      var reason = 'the server did not confirm the registration';
      try {
        confirmed = await _register(nodeId);
      } catch (error) {
        debugPrint('[NodeRegistrationService] attempt $attempt threw: $error');
        reason = 'could not reach the server';
      }

      if (generation != _generation) return true;

      if (confirmed) {
        _registeredNodeId = nodeId;
        _emit(RegistrationSucceeded(nodeId, _now()));
        return false;
      }

      final wait = _backoff[min(attempt - 1, _backoff.length - 1)];
      _emit(RegistrationFailed(reason, attempt, _now().add(wait)));
      await _delay(wait);
    }
  }

  void _emit(RegistrationStatus status) {
    _status = status;
    if (!_controller.isClosed) _controller.add(status);
  }

  void dispose() {
    _disposed = true;
    // Bumped so an attempt still in flight abandons itself instead of emitting
    // into a closed controller.
    _generation += 1;
    unawaited(_controller.close());
  }
}
