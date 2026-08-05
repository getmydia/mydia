/// One rung of the playback quality ladder.
///
/// A rung is a deliberate viewer choice, not an adaptive-bitrate level: the
/// server emits a single rendition per session, so switching rungs restarts
/// the session at new encoder settings. See
/// `docs/superpowers/specs/2026-08-04-player-quality-switcher-design.md`.
class QualityRung {
  /// Shown in the picker and on the control's tooltip.
  final String label;

  /// Output height ceiling in pixels, or null for the source resolution.
  final int? height;

  /// Total kbps cap covering video and audio, or null for no cap.
  ///
  /// Kilobits, deliberately: the GraphQL `maxBitrate` argument is kbps while
  /// `streamingMetadata.bitrate` is bits per second. Mixing them yields a
  /// 1000x error that presents as the cap being ignored.
  final int? maxBitrateKbps;

  const QualityRung({
    required this.label,
    this.height,
    this.maxBitrateKbps,
  });

  /// No caps at all, which preserves the copy-when-compatible path and is the
  /// cheapest option for the server.
  static const original = QualityRung(label: 'Original');

  bool get isOriginal => height == null;

  /// Key used in secure storage.
  ///
  /// Original persists as `auto` rather than `Original` because
  /// `settings_service.dart` has defaulted `default_quality` to `auto` since
  /// long before any of this was wired up. Reusing that key means an
  /// existing install reads its stored value as Original instead of failing
  /// to parse it.
  String get storageKey => isOriginal ? 'auto' : label;

  /// Parses a stored key, returning null if it is unrecognised.
  ///
  /// Callers fall back to [original] rather than treating an unknown value
  /// as fatal: it may have been written by a newer build.
  static QualityRung? fromStorageKey(String key) {
    if (key == 'auto') return original;
    for (final rung in _allRungs) {
      if (rung.label == key) return rung;
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is QualityRung &&
          runtimeType == other.runtimeType &&
          label == other.label &&
          height == other.height &&
          maxBitrateKbps == other.maxBitrateKbps;

  @override
  int get hashCode => Object.hash(label, height, maxBitrateKbps);

  @override
  String toString() => 'QualityRung($label)';
}

/// The full ladder, highest quality first, before filtering against a source.
const _allRungs = <QualityRung>[
  QualityRung(label: '1080p', height: 1080, maxBitrateKbps: 8000),
  QualityRung(label: '720p', height: 720, maxBitrateKbps: 4000),
  QualityRung(label: '480p', height: 480, maxBitrateKbps: 1500),
  QualityRung(label: '360p', height: 360, maxBitrateKbps: 800),
];

/// Builds the ladder offered for a source of [sourceHeight] pixels.
///
/// Rungs at or above the source are omitted: one equal to it is Original with
/// extra CPU cost, and one above it would upscale, burning encode time to
/// produce a larger, blurrier picture. A source shorter than every rung, or
/// one whose height is unknown, yields Original alone, and callers should
/// hide the control rather than open a one-item menu.
List<QualityRung> deriveQualityLadder({int? sourceHeight}) {
  if (sourceHeight == null || sourceHeight <= 0) {
    return const [QualityRung.original];
  }
  return [
    QualityRung.original,
    ..._allRungs.where((rung) => rung.height! < sourceHeight),
  ];
}

/// Names what the server actually applied, for labelling the control.
///
/// The server may clamp below what was requested, and a relay clamps to a
/// pair that is not on the ladder at all (2000kbps with 720p). Height is the
/// more meaningful half of that pair to a viewer, so it decides the label and
/// the bitrate is only a tiebreak.
QualityRung? effectiveRungLabel({int? maxHeight, int? maxBitrateKbps}) {
  if (maxHeight == null && maxBitrateKbps == null) {
    return QualityRung.original;
  }
  if (maxHeight == null) return null;
  for (final rung in _allRungs) {
    if (rung.height == maxHeight) return rung;
  }
  return null;
}
