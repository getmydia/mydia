import '../../domain/models/download_option.dart';

/// Abstract interface for download job services.
///
/// Each source that prepares downloads server-side provides the same
/// operations:
/// - Query available download quality options
/// - Prepare/start download transcode jobs
/// - Monitor job status and progress
/// - Cancel ongoing jobs
/// - Get download URLs
abstract class DownloadJobService {
  Future<DownloadOptionsResponse> getOptions(String contentType, String id);

  Future<DownloadJobStatus> prepareDownload({
    required String contentType,
    required String id,
    required String resolution,
  });

  Future<DownloadJobStatus> getJobStatus(String jobId);

  Future<void> cancelJob(String jobId);

  Future<String> getDownloadUrl(String jobId);
}

/// Exception thrown by DownloadJobService operations.
class DownloadServiceException implements Exception {
  final String message;
  final int? statusCode;

  DownloadServiceException(this.message, {this.statusCode});

  @override
  String toString() =>
      'DownloadServiceException: $message (status: $statusCode)';
}
