import 'package:flutter/foundation.dart';

import 'fullscreen_report.dart';

/// The last fullscreen report the player published, kept after the player
/// screen is gone.
///
/// It has to outlive the screen. The sequence a bug report is made of is "play
/// something, tap fullscreen, nothing happens, go to settings and copy the
/// diagnostics", and by the final step the `FullscreenController` that knew
/// what happened has been disposed.
///
/// Same shape and same reasoning as `windowFullscreenSignal`: a platform-free
/// global signal, one intended writer, read-only view for consumers, and no
/// `@visibleForTesting` annotation because that fires
/// `invalid_use_of_visible_for_testing_member` the moment a different library
/// file writes to it.
///
/// Null until a player screen has run at least once, which is the honest answer
/// for a session that has never played anything.
final ValueNotifier<FullscreenReport?> fullscreenReportSignal =
    ValueNotifier<FullscreenReport?>(null);

/// Read-only view of [fullscreenReportSignal] for consumers.
ValueListenable<FullscreenReport?> get fullscreenReport =>
    fullscreenReportSignal;
