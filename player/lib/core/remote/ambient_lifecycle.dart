import 'dart:async';

import 'package:flutter/widgets.dart' show AppLifecycleState;

import 'ambient_targets.dart';

/// What a raw [AppLifecycleState] transition means for an [AmbientTargets]'
/// held connections.
enum AmbientLifecycleAction {
  /// Drop every held connection now (see [AmbientTargets.onBackground]).
  background,

  /// Re-sweep (see [AmbientTargets.sweep]) — this is the "next foreground
  /// sweep" [AmbientTargets]' own class doc names as the recovery path.
  foreground,

  /// No opinion; leave whatever is currently held alone.
  none,
}

/// Maps [state] onto the action [AmbientTargets] should take.
///
/// [AppLifecycleState.paused] counts because it is the unambiguous
/// mobile/desktop "not running in the foreground any more" state — the
/// framework's own dartdoc on it says it "is only entered on iOS and
/// Android". [AppLifecycleState.detached] counts too: it is the state
/// entered right before teardown, or (per its own dartdoc) synthesized on
/// Android/iOS/web "after all views have been detached" — never a state
/// worth holding a live, polled p2p connection through.
///
/// [AppLifecycleState.hidden] is folded into [AmbientLifecycleAction.background]
/// as well, deliberately going further than "paused and detached" alone.
/// Two reasons:
///
///  * The framework's own [AppLifecycleState.hidden] dartdoc recommends
///    exactly this: "This allows cross-platform implementations that want
///    to know when an app is conceptually 'hidden' to only write one
///    handler" — `hidden` is synthesized before `paused` is entered on
///    iOS/Android, so treating it the same as `paused` costs nothing there.
///  * `paused` is never reached at all on Flutter Web (again, per its own
///    dartdoc), and `player/CLAUDE.md` names Flutter Web — served through
///    Phoenix at `/player` — as this app's primary deployment. `hidden` is
///    the *only* signal a browser tab switch or minimize ever produces.
///    `AmbientTargets` genuinely runs there too: `P2pService` has explicit
///    `kIsWeb` handling (`core/p2p/p2p_service.dart`) for exactly this
///    p2p stack. Restricting this mapping to `paused`/`detached` alone
///    would leave held connections running indefinitely on the one build
///    most likely to actually background this app.
///
/// [AppLifecycleState.inactive] never counts. Per its own dartdoc, it
/// covers a notification shade pull, an incoming call, TouchID, or the app
/// switcher on iOS, and a partially-obscured window on Android — all
/// still-foreground-ish and momentary. Treating those as background would
/// tear down and immediately re-establish held connections for no benefit,
/// exactly the "pointless churn" `AmbientTargets`' bound on held targets
/// exists to avoid.
AmbientLifecycleAction ambientLifecycleAction(AppLifecycleState state) {
  switch (state) {
    case AppLifecycleState.paused:
    case AppLifecycleState.detached:
    case AppLifecycleState.hidden:
      return AmbientLifecycleAction.background;
    case AppLifecycleState.resumed:
      return AmbientLifecycleAction.foreground;
    case AppLifecycleState.inactive:
      return AmbientLifecycleAction.none;
  }
}

/// Applies real app-lifecycle transitions to whichever [AmbientTargets] is
/// currently live, so `_MyAppState.didChangeAppLifecycleState`
/// (`app.dart`) has one small, independently testable thing to delegate to
/// instead of hand-rolling this inline — the same split `ResumeGate` /
/// `applyAppLifecycleState` (`core/graphql/watch/resume_gate.dart`) already
/// uses for the unrelated resume-refetch decision.
class AmbientLifecycleBinding {
  AmbientLifecycleBinding(this.targets);

  /// Resolves the live [AmbientTargets] to act on, or `null` before the p2p
  /// stack is ready. Called fresh on every [handle] rather than captured
  /// once: `ambientTargetsProvider` (`core/cast/cast_providers.dart`) can
  /// rebuild — disposing its old [AmbientTargets] and replacing it with a
  /// new one — any time the p2p host or GraphQL client it reads changes,
  /// independent of app lifecycle (see that provider's own dartdoc). Reading
  /// fresh means every transition lands on whichever instance is actually
  /// live right now, not a stale one captured at construction time.
  final AmbientTargets? Function() targets;

  /// Whether the app is currently foregrounded, as this binding last heard
  /// it. Read again once an in-flight [AmbientTargets.sweep] resolves — see
  /// [_sweep] — because [AmbientTargets] has no way to cancel a sweep
  /// already in flight: by the time that `Future` completes it has already
  /// mutated the target's held connections and restarted its poll timer,
  /// regardless of what happened while it was awaiting. A background
  /// transition that arrives mid-sweep must not be silently overwritten by
  /// that sweep once it finally lands.
  bool _foreground = true;

  /// Called from `didChangeAppLifecycleState` on every raw transition.
  void handle(AppLifecycleState state) {
    switch (ambientLifecycleAction(state)) {
      case AmbientLifecycleAction.none:
        return;
      case AmbientLifecycleAction.background:
        _foreground = false;
        targets()?.onBackground();
      case AmbientLifecycleAction.foreground:
        _foreground = true;
        _sweep();
    }
  }

  void _sweep() {
    final current = targets();
    if (current == null) return;
    unawaited(current.sweep().then((_) {
      // The app may have backgrounded again while this sweep was still in
      // flight (see `_foreground`'s dartdoc). Undo it rather than leaving a
      // stale foreground sweep's connections open behind a backgrounded
      // app.
      if (!_foreground) current.onBackground();
    }));
  }
}
