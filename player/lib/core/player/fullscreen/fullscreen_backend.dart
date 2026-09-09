import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import 'fullscreen_failure.dart';
import 'fullscreen_mode.dart';
import 'fullscreen_report.dart';

/// The platform half of fullscreen.
///
/// Implementations own writing state: they call the `onChange` handed to
/// [createFullscreenBackend] whenever the platform *reports* a transition,
/// which for three of the four live modes means a real platform event rather
/// than an assumption. `FullscreenController` never writes its own notifier.
///
/// [enter] and [exit] are synchronous by contract. `webkitEnterFullscreen`
/// requires live user activation and any `await` before the call spends it.
/// This is also why failures arrive through the `onFailure` handed to
/// [createFullscreenBackend] rather than as a return value: the document route
/// answers through a `Promise`, so a synchronous `bool` would have to guess,
/// and guessing whether the platform complied is the original defect this
/// module exists to prevent.
abstract class FullscreenBackend {
  /// The route in use. Stable for the life of the process on native. On web it
  /// can demote once, when the route resolved at construction is refused at
  /// request time; [ready] and [report] are how that becomes visible.
  FullscreenMode get mode;

  /// Whether a request made right now would be carried out.
  ///
  /// Distinct from `mode != unsupported`, which only says the platform has an
  /// API. Readiness additionally covers "the route needs a media element and
  /// none is bound yet" and "this route has already been refused", which is
  /// what stops the control being drawn over a request that cannot succeed.
  ValueListenable<bool> get ready;

  /// A snapshot for the diagnostics readout. Cheap; built on demand.
  FullscreenReport get report;

  /// Hands over the media_kit player once it exists, so a web backend can
  /// reach the underlying `HTMLVideoElement`. A no-op on native.
  ///
  /// Safe and expected to call again with a different [Player]: `PlayerScreen`
  /// constructs a fresh one on every source load, and a backend still holding
  /// the previous one would be fullscreening a disposed element.
  void attach(Player player);

  void enter();

  void exit();

  void dispose();
}

/// Signature of the failure sink handed to [createFullscreenBackend].
typedef FullscreenFailureSink = void Function(FullscreenFailure failure);
