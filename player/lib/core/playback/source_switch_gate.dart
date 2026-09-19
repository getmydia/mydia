import 'dart:async';

/// Keeps subtitle calls off a player while a source switch replaces its
/// file.
///
/// A switch runs with the gate closed ([closeWhile]); a subtitle call runs
/// through [pass]. A call arriving during a switch waits for it to finish,
/// then asks `stillWanted` whether it still applies, so work the switch
/// superseded drops itself instead of reaching a player that is being
/// disposed (web) or is opening another file (native). A switch first waits
/// for calls already running, so it never replaces a file under one.
///
/// A switch must never await [pass] from inside [closeWhile]: the call would
/// wait for the gate to reopen, and the gate would wait for the switch.
class SourceSwitchGate {
  Completer<void>? _closed;

  /// Calls let through by [pass] that have not settled yet, with their
  /// errors swallowed: the caller of [pass] still sees the error, and a
  /// switch only needs to know they are done.
  final Set<Future<void>> _running = {};

  /// Whether a switch holds the gate.
  bool get closed => _closed != null;

  /// Runs [replace] with the gate closed, after every call already let
  /// through by [pass] has settled. Reopens when [replace] returns or throws.
  ///
  /// Closes before its first await, so a caller that checks [closed] right
  /// after calling this sees the switch. A second close while one is in
  /// flight is a [StateError]: switches are serialised by their callers, so
  /// that is a bug, not a queue.
  Future<T> closeWhile<T>(Future<T> Function() replace) async {
    if (_closed != null) {
      throw StateError('a source switch already holds the gate');
    }
    final closed = _closed = Completer<void>();
    try {
      await Future.wait(_running.toList());
      return await replace();
    } finally {
      _closed = null;
      closed.complete();
    }
  }

  /// Runs [call] once no switch holds the gate, if [stillWanted] is true at
  /// that moment, and returns whether it ran.
  ///
  /// [stillWanted] is asked after the wait and immediately before [call],
  /// with no await between them, so a switch cannot start in between.
  /// Errors from [call] reach the caller.
  Future<bool> pass(
    bool Function() stillWanted,
    Future<void> Function() call,
  ) async {
    // Loops: a new switch can close the gate again before this resumes.
    for (var closed = _closed; closed != null; closed = _closed) {
      await closed.future;
    }
    if (!stillWanted()) return false;

    final running = call();
    final settled = running.then<void>((_) {}, onError: (Object _) {});
    _running.add(settled);
    try {
      await running;
    } finally {
      _running.remove(settled);
    }
    return true;
  }
}
