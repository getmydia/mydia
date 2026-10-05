import 'package:gql/language.dart' show printNode;

import '../../domain/models/download_option.dart';
import '../../graphql/mutations/download_options.graphql.dart';
import '../../graphql/mutations/prepare_download.graphql.dart';
import '../../graphql/mutations/download_job_status.graphql.dart';
import '../../graphql/mutations/cancel_download_job.graphql.dart';
import '../p2p/local_proxy_service.dart';
import '../p2p/p2p_service.dart';
import 'download_job_parsing.dart';
import 'download_job_service.dart';

/// P2P-aware download job service that uses GraphQL over P2P.
///
/// This class implements [DownloadJobService] and routes all job management
/// requests through the P2P network via GraphQL. File downloads are served
/// through the local HTTP proxy, making them compatible with Dio/Range requests.
class P2pDownloadJobService implements DownloadJobService {
  final P2pService _p2pService;
  final LocalProxyService _localProxy;
  final String _serverNodeAddr;
  final String _authToken;

  P2pDownloadJobService({
    required P2pService p2pService,
    required LocalProxyService localProxy,
    required String serverNodeAddr,
    required String authToken,
  })  : _p2pService = p2pService,
        _localProxy = localProxy,
        _serverNodeAddr = serverNodeAddr,
        _authToken = authToken;

  // GraphQL query strings derived from generated document nodes
  // This ensures queries stay in sync with the .graphql files
  static final String _downloadOptionsQuery =
      printNode(documentNodeMutationDownloadOptions);
  static final String _prepareDownloadQuery =
      printNode(documentNodeMutationPrepareDownload);
  static final String _downloadJobStatusQuery =
      printNode(documentNodeMutationDownloadJobStatus);
  static final String _cancelDownloadJobQuery =
      printNode(documentNodeMutationCancelDownloadJob);

  @override
  Future<DownloadOptionsResponse> getOptions(
      String contentType, String id) async {
    final variables = {
      'contentType': contentType,
      'id': id,
    };

    final result = await _p2pService.sendGraphQLRequest(
      peer: _serverNodeAddr,
      query: _downloadOptionsQuery,
      variables: variables,
      operationName: 'DownloadOptions',
      authToken: _authToken,
    );

    return parseDownloadOptions(result);
  }

  @override
  Future<DownloadJobStatus> prepareDownload({
    required String contentType,
    required String id,
    required String resolution,
  }) async {
    final variables = {
      'contentType': contentType,
      'id': id,
      'resolution': resolution,
    };

    final result = await _p2pService.sendGraphQLRequest(
      peer: _serverNodeAddr,
      query: _prepareDownloadQuery,
      variables: variables,
      operationName: 'PrepareDownload',
      authToken: _authToken,
    );

    return parsePrepareDownload(result);
  }

  @override
  Future<DownloadJobStatus> getJobStatus(String jobId) async {
    final variables = {
      'jobId': jobId,
    };

    final result = await _p2pService.sendGraphQLRequest(
      peer: _serverNodeAddr,
      query: _downloadJobStatusQuery,
      variables: variables,
      operationName: 'DownloadJobStatus',
      authToken: _authToken,
    );

    return parseDownloadJobStatus(result);
  }

  @override
  Future<void> cancelJob(String jobId) async {
    final variables = {
      'jobId': jobId,
    };

    final result = await _p2pService.sendGraphQLRequest(
      peer: _serverNodeAddr,
      query: _cancelDownloadJobQuery,
      variables: variables,
      operationName: 'CancelDownloadJob',
      authToken: _authToken,
    );

    parseCancelDownloadJob(result);
  }

  @override
  Future<String> getDownloadUrl(String jobId) async {
    // Take a hold on the shared proxy either way, but only configure it when
    // nothing else has. Downloads and playback serve from one proxy, and
    // holding nothing is what let the player's `dispose()` stop it out from
    // under a transfer in progress. When the home target is already served
    // this joins it as an owner, so it also outlives the owner that started
    // it.
    //
    // The split matters: `start` re-targets a proxy that is already running,
    // and the peer and token here were captured when this service was built.
    // A token refresh since then leaves them stale, so configuring a proxy
    // playback is already streaming through would point it at the wrong token
    // and get playback's own range requests rejected.
    //
    // The hold outlives an individual job: nothing here observes a download
    // finishing, so once any download has run the proxy stays up for the rest
    // of the session. That is a loopback listener with no traffic on it,
    // which beats a download dying mid-transfer.
    if (!_localProxy.joinTarget(this)) {
      await _localProxy.start(
        owner: this,
        targetPeer: _serverNodeAddr,
        authToken: _authToken,
      );
    }
    return 'http://127.0.0.1:${_localProxy.port}/download/$jobId/file';
  }
}
