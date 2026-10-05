/// What a source hands the download pipeline: where the bytes are and how to
/// ask for them. Resolved fresh on every start and restart, never stored,
/// because connections move and tokens expire.
library;

sealed class DownloadPlan {
  const DownloadPlan();
}

/// A file the server already has, fetched as-is.
final class DirectFile extends DownloadPlan {
  const DirectFile({
    required this.url,
    this.headers = const {},
    required this.extension,
    this.expectedBytes,
  });

  final String url;

  /// Carries the credential, which never goes in [url].
  final Map<String, String> headers;

  /// Without the dot.
  final String extension;

  final int? expectedBytes;
}

/// One look at a server-side transcode job.
class JobSnapshot {
  const JobSnapshot({
    required this.jobId,
    required this.ready,
    required this.progress,
    this.fileSize,
    this.error,
  });

  final String jobId;

  /// The whole file exists on the server.
  final bool ready;

  /// 0.0 to 1.0.
  final double progress;

  /// Bytes produced so far, or the final size once [ready].
  final int? fileSize;

  final String? error;
}

/// A Mydia transcode job. The pipeline prepares it (or reuses the stored job
/// id), polls it, then fetches [file].
abstract class TranscodeJob extends DownloadPlan {
  const TranscodeJob();

  Future<JobSnapshot> prepare();

  /// Throws [DeadJobException] when the server no longer has [jobId].
  Future<JobSnapshot> status(String jobId);

  Future<void> cancel(String jobId);

  Future<DirectFile> file(String jobId);
}

/// The server dropped the job. Not recoverable by resuming, only by
/// restarting, which prepares a new one.
class DeadJobException implements Exception {
  const DeadJobException(this.message);

  final String message;

  @override
  String toString() => message;
}

final _safeExtension = RegExp(r'^[a-z0-9]{2,5}$');

/// The file extension for a server's container name, `mp4` when unknown.
String extensionForContainer(String? container) {
  final name = container?.split(',').first.trim().toLowerCase();
  if (name == null || name.isEmpty) return 'mp4';
  final mapped = switch (name) {
    'matroska' => 'mkv',
    'mpegts' => 'ts',
    'quicktime' => 'mov',
    _ => name,
  };
  return _safeExtension.hasMatch(mapped) ? mapped : 'mp4';
}
