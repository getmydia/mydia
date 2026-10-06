/// A Mydia server's transcode job, over HTTP or p2p.
library;

import '../../../domain/models/download_option.dart';
import '../../../domain/models/download_plan.dart';
import '../../../domain/sources/item.dart';
import '../../downloads/download_job_service.dart';

/// What Mydia's download API calls an item kind.
String mydiaContentType(ItemKind kind) =>
    kind == ItemKind.episode ? 'episode' : 'movie';

JobSnapshot _snapshot(DownloadJobStatus status) => JobSnapshot(
      jobId: status.jobId,
      ready: status.status == DownloadJobStatusType.ready,
      progress: status.progress,
      fileSize: status.currentFileSize,
      error: status.error,
    );

class MydiaTranscodeJob extends TranscodeJob {
  MydiaTranscodeJob({
    required this.jobs,
    required this.contentType,
    required this.id,
    required this.resolution,
    required this.fileFor,
  });

  final DownloadJobService jobs;
  final String contentType;
  final String id;
  final String resolution;

  /// Where the finished bytes are, which depends on the transport.
  final Future<DirectFile> Function(String jobId) fileFor;

  @override
  Future<JobSnapshot> prepare() async => _snapshot(await jobs.prepareDownload(
      contentType: contentType, id: id, resolution: resolution));

  @override
  Future<JobSnapshot> status(String jobId) async {
    try {
      return _snapshot(await jobs.getJobStatus(jobId));
    } on DownloadServiceException catch (e) {
      if (e.statusCode == 404) {
        throw const DeadJobException(
            'The server no longer has this download job. Restart to try again.');
      }
      rethrow;
    }
  }

  @override
  Future<void> cancel(String jobId) => jobs.cancelJob(jobId);

  @override
  Future<DirectFile> file(String jobId) => fileFor(jobId);
}
