/// What the player decided to play, and why.
///
/// See player/docs/playback.md, "The decision, and where to look when it is
/// wrong".
library;

import '../../domain/models/quality_rung.dart';

/// How an HLS session delivers the file.
enum HlsStrategy { copy, transcode }

enum QualityChoiceKind { auto, original, fixed }

/// The viewer's quality choice as the planner sees it.
///
/// Auto is the default and respects remembered decode failures. Original is
/// always the viewer's own pick, which overrides them. A fixed rung pins caps.
class QualityChoice {
  const QualityChoice._(this.kind, this.rung);

  const QualityChoice.fixed(QualityRung rung)
      : this._(QualityChoiceKind.fixed, rung);

  static const auto = QualityChoice._(QualityChoiceKind.auto, null);
  static const original = QualityChoice._(QualityChoiceKind.original, null);

  /// Auto maps to [auto], Original to [original]; anything with a cap is a
  /// fixed rung.
  factory QualityChoice.fromRung(QualityRung rung) => rung.isAuto
      ? auto
      : rung.isOriginal
          ? original
          : QualityChoice.fixed(rung);

  final QualityChoiceKind kind;

  /// Only set for [QualityChoiceKind.fixed].
  final QualityRung? rung;

  /// A fixed rung has caps to apply and only an encoder can apply them, so
  /// it never direct plays and never stream-copies.
  bool get allowsLossless => kind != QualityChoiceKind.fixed;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is QualityChoice && other.kind == kind && other.rung == rung;

  @override
  int get hashCode => Object.hash(kind, rung);

  @override
  String toString() => 'QualityChoice(${rung?.label ?? kind.name})';
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
