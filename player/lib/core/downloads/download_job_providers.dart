import 'dart:async';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../domain/models/download_option.dart';
import '../connection/connection_provider.dart';
import '../graphql/graphql_provider.dart';
import '../p2p/local_proxy_service.dart';
import '../p2p/p2p_service.dart';
import 'download_job_service.dart';
import 'p2p_download_job_service.dart';

part 'download_job_providers.g.dart';

/// Provider for the HTTP-based DownloadJobService instance.
///
/// Returns null if authentication is not available.
@riverpod
HttpDownloadJobService? downloadJobService(Ref ref) {
  final serverUrlAsync = ref.watch(serverUrlProvider);
  final authTokenAsync = ref.watch(authTokenProvider);
  final mediaTokenService = ref.watch(mediaTokenServiceProvider);

  if (mediaTokenService == null) {
    return null;
  }

  return serverUrlAsync.when(
    data: (serverUrl) {
      if (serverUrl == null) return null;

      return authTokenAsync.when(
        data: (authToken) {
          if (authToken == null) return null;

          return HttpDownloadJobService(
            baseUrl: serverUrl,
            authToken: authToken,
            mediaTokenService: mediaTokenService,
          );
        },
        loading: () => null,
        error: (_, __) => null,
      );
    },
    loading: () => null,
    error: (_, __) => null,
  );
}

/// Provider for the P2P-based download job service.
///
/// Returns null if not in P2P mode or authentication is not available.
@riverpod
P2pDownloadJobService? p2pDownloadJobService(Ref ref) {
  final connectionState = ref.watch(connectionProvider);
  if (!connectionState.isP2PMode || connectionState.serverNodeAddr == null) {
    return null;
  }

  final authTokenAsync = ref.watch(authTokenProvider);
  final p2pService = ref.watch(p2pServiceProvider);
  final localProxy = ref.watch(localProxyServiceProvider);

  return authTokenAsync.when(
    data: (authToken) {
      if (authToken == null) return null;

      return P2pDownloadJobService(
        p2pService: p2pService,
        localProxy: localProxy,
        serverNodeAddr: connectionState.serverNodeAddr!,
        authToken: authToken,
      );
    },
    loading: () => null,
    error: (_, __) => null,
  );
}

/// Provider that returns true if currently in P2P mode.
@riverpod
bool isP2PDownloadMode(Ref ref) {
  final connectionState = ref.watch(connectionProvider);
  return connectionState.isP2PMode && connectionState.serverNodeAddr != null;
}

/// Unified provider that returns the appropriate [DownloadJobService]
/// based on the current connection mode (P2P or direct HTTP).
///
/// Returns null if no service is available.
@riverpod
DownloadJobService? unifiedDownloadJobService(Ref ref) {
  final isP2PMode = ref.watch(isP2PDownloadModeProvider);

  if (isP2PMode) {
    return ref.watch(p2pDownloadJobServiceProvider);
  }

  return ref.watch(downloadJobServiceProvider);
}

/// Provider for fetching download quality options.
///
/// [contentType] must be either "movie" or "episode"
/// [id] is the media item ID (movie ID or episode ID)
///
/// Returns available quality options with estimated file sizes.
/// Automatically uses the correct service based on connection mode.
@riverpod
Future<DownloadOptionsResponse> downloadOptions(
  Ref ref,
  String contentType,
  String id,
) async {
  final service = ref.watch(unifiedDownloadJobServiceProvider);
  if (service == null) {
    throw Exception('Download service not available');
  }
  return await service.getOptions(contentType, id);
}

/// Provider for monitoring download job status with auto-polling.
///
/// [jobId] is the unique job identifier.
///
/// Automatically polls for status updates every 2 seconds while job is in progress.
/// Stops polling once job is complete (ready or failed).
@riverpod
Stream<DownloadJobStatus> downloadJobStatus(
  Ref ref,
  String jobId,
) async* {
  final service = ref.watch(unifiedDownloadJobServiceProvider);
  if (service == null) {
    throw Exception('Download service not available');
  }

  // Poll for status updates
  const pollInterval = Duration(seconds: 2);
  DownloadJobStatus? lastStatus;

  while (true) {
    try {
      final status = await service.getJobStatus(jobId);

      // Yield new status
      yield status;
      lastStatus = status;

      // Stop polling if job is complete
      if (status.isComplete) {
        break;
      }

      // Wait before next poll
      await Future<void>.delayed(pollInterval);
    } catch (e) {
      // If we had a previous status, we can continue with that
      if (lastStatus != null) {
        // Job might have been deleted/cancelled, treat as complete
        if (e is DownloadServiceException && e.statusCode == 404) {
          break;
        }
      }
      rethrow;
    }
  }
}

/// Provider for preparing a download job.
///
/// This is a family provider that can be used to initiate download preparation.
/// Use `ref.refresh()` to start a new preparation.
@riverpod
Future<DownloadJobStatus> prepareDownload(
  Ref ref, {
  required String contentType,
  required String id,
  required String resolution,
}) async {
  final service = ref.watch(unifiedDownloadJobServiceProvider);
  if (service == null) {
    throw Exception('Download service not available');
  }

  return await service.prepareDownload(
    contentType: contentType,
    id: id,
    resolution: resolution,
  );
}

/// Provider for getting authenticated download URL.
///
/// [jobId] is the unique job identifier.
///
/// Returns a URL with authentication token that can be used to download the file.
@riverpod
Future<String> downloadUrl(Ref ref, String jobId) async {
  final service = ref.watch(unifiedDownloadJobServiceProvider);
  if (service == null) {
    throw Exception('Download service not available');
  }

  return await service.getDownloadUrl(jobId);
}
