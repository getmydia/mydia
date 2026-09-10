import 'package:flutter/foundation.dart';

/// Why a fullscreen request could not be carried out.
///
/// Every value here used to be a bare `debugPrint` inside
/// `WebFullscreenBackend`. On a phone that output is unreachable without a Mac
/// and Safari Web Inspector attached, which is exactly why "the fullscreen
/// button does nothing on iOS Safari" could not be diagnosed from the device it
/// happened on. Naming the causes is what makes them reportable: to the viewer
/// as a message, and to `DiagnosticsScreen` as a line a bug report can carry.
enum FullscreenFailureCause {
  /// `document.fullscreenEnabled` could not be read at all.
  documentEnabledProbeFailed,

  /// The `HTMLVideoElement.prototype` capability probe threw.
  videoSupportProbeFailed,

  /// `requestFullscreen()` was rejected by the browser.
  documentRequestRejected,

  /// `exitFullscreen()` was rejected by the browser.
  documentExitRejected,

  /// The media player was not the web implementation, so no media element
  /// could be reached to fullscreen.
  playerNotWebPlayer,

  /// The media element route is in use but nothing is bound to fullscreen.
  noVideoElement,

  /// `webkitEnterFullscreen()` threw.
  videoEnterFailed,

  /// `webkitExitFullscreen()` threw.
  videoExitFailed,
}

/// A single refusal, with enough detail to put in a bug report and not so much
/// that it belongs in front of a viewer.
///
/// [detail] carries the platform's own words where there were any. It is for
/// the diagnostics readout; the message shown during playback stays plain,
/// because a WebKit rejection reason is not something a viewer can act on.
@immutable
class FullscreenFailure {
  const FullscreenFailure(
    this.cause, {
    this.detail,
    this.requestInitiated = false,
  });

  final FullscreenFailureCause cause;
  final String? detail;

  /// Whether this followed an explicit request from the viewer.
  ///
  /// Only these are worth a message. A capability probe that threw while the
  /// screen was opening, or a media element that could not be bound during
  /// source setup, are real and belong in the readout, but telling someone who
  /// has not asked for fullscreen that fullscreen failed is noise.
  final bool requestInitiated;

  /// One line, safe to copy out of `DiagnosticsScreen`.
  String get label => switch (cause) {
        FullscreenFailureCause.documentEnabledProbeFailed =>
          'document.fullscreenEnabled could not be read',
        FullscreenFailureCause.videoSupportProbeFailed =>
          'video element capability probe failed',
        FullscreenFailureCause.documentRequestRejected =>
          'requestFullscreen was rejected',
        FullscreenFailureCause.documentExitRejected =>
          'exitFullscreen was rejected',
        FullscreenFailureCause.playerNotWebPlayer =>
          'player is not the web implementation',
        FullscreenFailureCause.noVideoElement => 'no media element bound',
        FullscreenFailureCause.videoEnterFailed =>
          'webkitEnterFullscreen failed',
        FullscreenFailureCause.videoExitFailed => 'webkitExitFullscreen failed',
      };

  @override
  String toString() => detail == null ? label : '$label: $detail';

  @override
  bool operator ==(Object other) =>
      other is FullscreenFailure &&
      other.cause == cause &&
      other.detail == detail &&
      other.requestInitiated == requestInitiated;

  @override
  int get hashCode => Object.hash(cause, detail, requestInitiated);
}
