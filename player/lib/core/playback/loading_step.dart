/// What the player is doing while it opens a stream, as a value the screen
/// words in the viewer's language (`AppFormatters.loadingStepText`).
///
/// The transports report these through `onProgress`; none of them has a
/// `BuildContext`, so none of them writes a sentence.
library;

enum LoadingStepKind {
  /// Asking the server to start a stream.
  startingStream,

  /// The server is transcoding; [LoadingStep.percent] says how far.
  preparingStream,

  /// Waiting for the transcode to produce a playlist;
  /// [LoadingStep.attempt] of [LoadingStep.maxAttempts].
  startingTranscode,

  /// Reaching the server over the peer-to-peer connection.
  connectingP2p,

  /// Asking the server which files and codecs are on offer.
  checkingCompatibility,
}

class LoadingStep {
  const LoadingStep(
    this.kind, {
    this.percent = 0,
    this.attempt = 0,
    this.maxAttempts = 0,
  });

  final LoadingStepKind kind;
  final int percent;
  final int attempt;
  final int maxAttempts;

  @override
  bool operator ==(Object other) =>
      other is LoadingStep &&
      other.kind == kind &&
      other.percent == percent &&
      other.attempt == attempt &&
      other.maxAttempts == maxAttempts;

  @override
  int get hashCode => Object.hash(kind, percent, attempt, maxAttempts);

  @override
  String toString() => 'LoadingStep($kind, $percent%, $attempt/$maxAttempts)';
}
