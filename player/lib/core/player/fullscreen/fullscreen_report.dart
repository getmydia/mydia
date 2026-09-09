import 'package:flutter/foundation.dart';

import 'fullscreen_failure.dart';
import 'fullscreen_mode.dart';

/// What the fullscreen module currently believes, in a form a bug report can
/// carry.
///
/// This exists because the failure it describes is only reachable on devices
/// this repo cannot test: `flutter test` always runs non-web, and the reporter
/// is on an iPhone with no console. `DiagnosticsScreen` already exists so a bug
/// report can carry the whole picture without a screenshot, and this is the
/// playback half of that picture.
///
/// [documentFullscreenEnabled] and [videoElementFullscreenSupported] are the
/// two probes `resolveWebMode` ran, and are null on native builds where neither
/// applies. They are reported separately from [mode] on purpose: "this browser
/// has no fullscreen at all" and "we picked a route and it refused" are the two
/// answers being told apart, and [mode] alone cannot distinguish them once
/// [demoted] is involved.
@immutable
class FullscreenReport {
  const FullscreenReport({
    required this.mode,
    required this.ready,
    this.mediaElementBound = false,
    this.demoted = false,
    this.lastFailure,
    this.documentFullscreenEnabled,
    this.videoElementFullscreenSupported,
  });

  /// The route in use right now, after any demotion.
  final FullscreenMode mode;

  /// Whether a request made at this moment would be carried out. This is what
  /// the control's presence follows, not [mode].
  final bool ready;

  /// Whether a media element is bound for the video element route. Always
  /// false on the document route and on native.
  final bool mediaElementBound;

  /// Whether the initially resolved route was refused at request time and the
  /// backend fell back. One-way for the life of the session.
  final bool demoted;

  /// The most recent refusal, if any. Not cleared on a later success, because
  /// its whole audience is someone reading back what went wrong.
  final FullscreenFailure? lastFailure;

  /// `document.fullscreenEnabled` as read at construction. Null on native.
  final bool? documentFullscreenEnabled;

  /// Whether `HTMLVideoElement.prototype` carried `webkitEnterFullscreen`.
  /// Null on native.
  final bool? videoElementFullscreenSupported;

  FullscreenReport copyWith({
    FullscreenMode? mode,
    bool? ready,
    bool? mediaElementBound,
    bool? demoted,
    FullscreenFailure? lastFailure,
  }) =>
      FullscreenReport(
        mode: mode ?? this.mode,
        ready: ready ?? this.ready,
        mediaElementBound: mediaElementBound ?? this.mediaElementBound,
        demoted: demoted ?? this.demoted,
        lastFailure: lastFailure ?? this.lastFailure,
        documentFullscreenEnabled: documentFullscreenEnabled,
        videoElementFullscreenSupported: videoElementFullscreenSupported,
      );

  /// Rows for the diagnostics readout, in display order.
  ///
  /// Pure and shared by the section and the copy button so the two cannot drift
  /// apart, which is the failure mode of every hand-maintained "copy
  /// diagnostics" that lists fewer fields than the screen above it.
  List<(String label, String value)> get rows => [
        ('Route', mode.name),
        ('Ready', ready ? 'yes' : 'no'),
        if (mode == FullscreenMode.nativeVideoElement)
          ('Media element', mediaElementBound ? 'bound' : 'not bound'),
        if (demoted) ('Fell back', 'yes'),
        if (documentFullscreenEnabled != null)
          ('document.fullscreenEnabled', '$documentFullscreenEnabled'),
        if (videoElementFullscreenSupported != null)
          ('Video element fullscreen', '$videoElementFullscreenSupported'),
        if (lastFailure != null) ('Last failure', '$lastFailure'),
      ];

  @override
  String toString() => 'FullscreenReport(mode: ${mode.name}, ready: $ready, '
      'mediaElementBound: $mediaElementBound, demoted: $demoted, '
      'lastFailure: $lastFailure, '
      'documentFullscreenEnabled: $documentFullscreenEnabled, '
      'videoElementFullscreenSupported: $videoElementFullscreenSupported)';
}

/// The Playback block of a copied diagnostics report.
///
/// Empty when nothing has played this session, so a bug report about something
/// else does not carry a section of "unknown" rows.
List<String> fullscreenReportLines(FullscreenReport? report) {
  if (report == null) return const [];
  return [
    'Fullscreen:',
    for (final (label, value) in report.rows) '  $label: $value',
  ];
}
