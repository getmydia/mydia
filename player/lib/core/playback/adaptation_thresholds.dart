/// Every number the adaptation policy compares against, in one place.
///
/// Tests shrink them through the constructor.
library;

class AdaptationThresholds {
  const AdaptationThresholds({
    this.verificationWindow = const Duration(seconds: 20),
    this.dropWindow = const Duration(seconds: 10),
    this.maxDropsPerSecond = 1.0,
    this.verificationStalls = 2,
    this.laterStalls = 3,
    this.laterStallWindow = const Duration(seconds: 120),
    this.drainSamples = 15,
    this.drainBelow = const Duration(seconds: 10),
    this.sustainedDropWindows = 3,
  });

  /// Playing time after a source starts during which the strict thresholds
  /// apply.
  final Duration verificationWindow;

  /// Sliding window over which dropped frames are averaged.
  final Duration dropWindow;

  /// Average dropped frames per second above which decode is too slow.
  final double maxDropsPerSecond;

  /// Stalls during verification that mean bandwidth cannot carry the file.
  final int verificationStalls;

  /// Stalls within [laterStallWindow], after verification, that mean the same.
  final int laterStalls;
  final Duration laterStallWindow;

  /// Consecutive samples of shrinking buffer, all under [drainBelow], that
  /// mean the link is slower than the stream.
  final int drainSamples;
  final Duration drainBelow;

  /// After verification, consecutive [dropWindow]s that must each exceed
  /// [maxDropsPerSecond] before decode counts as too slow.
  final int sustainedDropWindows;
}
