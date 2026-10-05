/// Mydia's download mutations, sent to a guest server.
library;

import 'package:gql/ast.dart';

import '../../../domain/models/download_option.dart';
import '../../../graphql/mutations/cancel_download_job.graphql.dart';
import '../../../graphql/mutations/download_job_status.graphql.dart';
import '../../../graphql/mutations/download_options.graphql.dart';
import '../../../graphql/mutations/prepare_download.graphql.dart';
import '../../downloads/download_job_parsing.dart';
import '../../downloads/download_job_service.dart';

/// `MydiaGuestClient.request`, which refreshes the guest's token on a 401.
typedef GuestRequest = Future<Map<String, dynamic>> Function(
    DocumentNode document, Map<String, dynamic> variables);

class GuestDownloadJobService implements DownloadJobService {
  GuestDownloadJobService({required this.request});

  final GuestRequest request;

  @override
  Future<DownloadOptionsResponse> getOptions(
          String contentType, String id) async =>
      parseDownloadOptions(await request(documentNodeMutationDownloadOptions,
          {'contentType': contentType, 'id': id}));

  @override
  Future<DownloadJobStatus> prepareDownload({
    required String contentType,
    required String id,
    required String resolution,
  }) async =>
      parsePrepareDownload(await request(documentNodeMutationPrepareDownload,
          {'contentType': contentType, 'id': id, 'resolution': resolution}));

  @override
  Future<DownloadJobStatus> getJobStatus(String jobId) async =>
      parseDownloadJobStatus(await request(
          documentNodeMutationDownloadJobStatus, {'jobId': jobId}));

  @override
  Future<void> cancelJob(String jobId) async => parseCancelDownloadJob(
      await request(documentNodeMutationCancelDownloadJob, {'jobId': jobId}));

  /// A guest's file URL depends on its transport and needs headers, so
  /// `MydiaGuestSource.resolve` builds it rather than this.
  @override
  Future<String> getDownloadUrl(String jobId) =>
      throw UnsupportedError('guest file URLs come from MydiaGuestSource');
}
