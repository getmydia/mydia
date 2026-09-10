/// What the player decided to play, and why.
///
/// See docs/superpowers/specs/2026-09-08-playback-decision-and-adaptation-design.md,
/// "The decision".
library;

import '../../domain/models/quality_rung.dart';

/// How an HLS session delivers the file.
enum HlsStrategy { copy, transcode }

enum QualityChoiceKind { auto, original, fixed }

/// The viewer's quality choice as the planner sees it.
///
/// `auto` exists from this phase so the planner has one shape, but nothing
/// offers it to the viewer until the Auto rung ships.
class QualityChoice {
  const QualityChoice._(this.kind, this.rung, {this.manual = false});

  const QualityChoice.fixed(QualityRung rung)
      : this._(QualityChoiceKind.fixed, rung);

  static const auto = QualityChoice._(QualityChoiceKind.auto, null);
  static const original = QualityChoice._(QualityChoiceKind.original, null);

  /// Original maps to [original]; anything with a cap is a fixed rung.
  ///
  /// [manual] only ever matters for Original: it is what lets the planner
  /// tell "the viewer picked Original in the quality menu" apart from "this
  /// is where a fresh playback starts, or what a carried default settled
  /// on." A fixed rung has no memory bypass to grant, so it ignores the
  /// flag.
  factory QualityChoice.fromRung(QualityRung rung, {bool manual = false}) =>
      rung.isOriginal
          ? QualityChoice._(QualityChoiceKind.original, null, manual: manual)
          : QualityChoice.fixed(rung);

  final QualityChoiceKind kind;

  /// Only set for [QualityChoiceKind.fixed].
  final QualityRung? rung;

  /// True only for a viewer-picked Original: see [fromRung]. Always false
  /// for [auto] and [fixed], irrelevant to fixed, and Auto has no manual
  /// pick to make until it ships.
  final bool manual;

  /// A fixed rung has caps to apply and only an encoder can apply them, so
  /// it never direct plays and never stream-copies.
  bool get allowsLossless => kind != QualityChoiceKind.fixed;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is QualityChoice &&
          other.kind == kind &&
          other.rung == rung &&
          other.manual == manual;

  @override
  int get hashCode => Object.hash(kind, rung, manual);

  @override
  String toString() {
    final label = rung?.label ?? kind.name;
    return manual ? 'QualityChoice($label, manual)' : 'QualityChoice($label)';
  }
}

/// One entry of `streamingCandidates.candidates`, in server order.
class CandidateStrategy {
  const CandidateStrategy({
    required this.strategy,
    required this.mime,
    this.videoCodec,
  });

  /// `DIRECT_PLAY`, `REMUX`, `HLS_COPY` or `TRANSCODE`.
  final String strategy;

  /// Full MIME with codecs, what `MediaSource.isTypeSupported` judges.
  final String mime;

  /// RFC 6381 video codec string, e.g. `hvc1.2.4.L120.B0`.
  final String? videoCodec;
}

/// The shape of a file as the failure memory keys it.
///
/// The RFC 6381 string already encodes codec and profile (so Main 10 versus
/// Main), which is what a decoder refuses on. Container is deliberately not
/// part of it: a codec that will not decode will not decode in any container.
class FileShape {
  const FileShape({required this.videoCodec, required this.heightBucket});

  factory FileShape.fromCandidates(
    List<CandidateStrategy> candidates, {
    required int? sourceHeight,
  }) {
    final codec = candidates.isEmpty ? null : candidates.first.videoCodec;
    return FileShape(
      videoCodec: (codec == null || codec.isEmpty) ? 'unknown' : codec,
      heightBucket: bucketHeight(sourceHeight),
    );
  }

  final String videoCodec;
  final int heightBucket;

  static const _buckets = [480, 720, 1080, 2160];

  /// The smallest of 480, 720, 1080 and 2160 at or above [height]; taller
  /// than every bucket lands in 2160; unknown is 0.
  static int bucketHeight(int? height) {
    if (height == null || height <= 0) return 0;
    for (final bucket in _buckets) {
      if (height <= bucket) return bucket;
    }
    return _buckets.last;
  }
}

/// The rule that produced a plan. Logged once per decision.
enum PlanReason {
  directPlayAccepted,
  copyAccepted,
  copyRejectedByMime,
  shapeKnownToFail,
  bitrateExceedsThroughput,
  fixedRungRequested,
  noDirectPlayCandidate,
  noCopyCandidate,
  webNeverDirectPlays,
  fallbackFromFailure,
}

sealed class PlaybackPlan {
  const PlaybackPlan({required this.reason});

  final PlanReason reason;

  /// One line for the decision log.
  String describe();
}

final class DirectPlayPlan extends PlaybackPlan {
  const DirectPlayPlan({required super.reason});

  @override
  String describe() => 'directPlay (${reason.name})';
}

final class HlsPlan extends PlaybackPlan {
  const HlsPlan({
    required this.strategy,
    required this.rung,
    required this.adaptive,
    required super.reason,
  });

  final HlsStrategy strategy;

  /// The caps to send. [QualityRung.original] sends none.
  final QualityRung rung;

  /// True when the session may change rendition on its own. Nothing acts on
  /// it in this phase; it records the intent for the Auto rung.
  final bool adaptive;

  @override
  String describe() =>
      '${strategy.name} ${rung.label}${adaptive ? ' adaptive' : ''} '
      '(${reason.name})';
}
