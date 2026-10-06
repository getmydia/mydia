/// Reads Mydia's download GraphQL answers, whichever transport carried them.
library;

import '../../domain/models/download_option.dart';
import 'download_job_service.dart';

DownloadOptionsResponse parseDownloadOptions(Map<String, dynamic> data) {
  final optionsData = data['downloadOptions'] as List<dynamic>?;
  if (optionsData == null) {
    throw DownloadServiceException('No options returned', statusCode: 400);
  }

  final options = optionsData.map((item) {
    final map = item as Map<String, dynamic>;
    return DownloadOption(
      resolution: map['resolution'] as String,
      label: map['label'] as String,
      estimatedSize: map['estimatedSize'] as int,
      transcodeStatus: map['transcodeStatus'] as String?,
      transcodeProgress: (map['transcodeProgress'] as num?)?.toDouble(),
      actualSize: map['actualSize'] as int?,
    );
  }).toList();

  return DownloadOptionsResponse(options: options);
}

DownloadJobStatus parsePrepareDownload(Map<String, dynamic> data) {
  final prepareData = data['prepareDownload'] as Map<String, dynamic>?;
  if (prepareData == null) {
    throw DownloadServiceException('Failed to prepare download',
        statusCode: 500);
  }

  return DownloadJobStatus(
    jobId: prepareData['jobId'] as String,
    status: DownloadJobStatusType.fromString(prepareData['status'] as String),
    progress: (prepareData['progress'] as num).toDouble(),
    error: prepareData['error'] as String?,
    currentFileSize: prepareData['fileSize'] as int?,
  );
}

DownloadJobStatus parseDownloadJobStatus(Map<String, dynamic> data) {
  final statusData = data['downloadJobStatus'] as Map<String, dynamic>?;
  if (statusData == null) {
    throw DownloadServiceException('Job not found', statusCode: 404);
  }

  return DownloadJobStatus(
    jobId: statusData['jobId'] as String,
    status: DownloadJobStatusType.fromString(statusData['status'] as String),
    progress: (statusData['progress'] as num).toDouble(),
    error: statusData['error'] as String?,
    currentFileSize: statusData['fileSize'] as int?,
  );
}

/// Throws unless the server confirmed the cancel.
bool parseCancelDownloadJob(Map<String, dynamic> data) {
  final cancelData = data['cancelDownloadJob'] as Map<String, dynamic>?;
  if (cancelData == null || cancelData['success'] != true) {
    throw DownloadServiceException('Failed to cancel job', statusCode: 500);
  }
  return true;
}
