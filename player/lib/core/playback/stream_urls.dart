/// Where the bytes come from, for each connection mode.
library;

import '../p2p/media_proxy.dart';

class ResolvedSource {
  const ResolvedSource({
    required this.url,
    required this.headers,
    this.probeHeaders,
  });

  final String url;
  final Map<String, String> headers;
  final Map<String, String>? probeHeaders;
}

abstract class StreamUrls {
  Future<ResolvedSource> directPlay(String fileId);
  ResolvedSource hls(String sessionId);
}

class ProxyStreamUrls implements StreamUrls {
  ProxyStreamUrls(this._proxy);

  final MediaProxy _proxy;

  @override
  Future<ResolvedSource> directPlay(String fileId) async => ResolvedSource(
        url: _proxy.buildDirectStreamUrl(fileId),
        headers: const {},
      );

  @override
  ResolvedSource hls(String sessionId) => ResolvedSource(
        url: _proxy.buildHlsUrl(sessionId),
        headers: const {},
      );
}

class HttpStreamUrls implements StreamUrls {
  HttpStreamUrls({
    required this.serverUrl,
    required this.bearerToken,
    required this.mediaToken,
  });

  final String serverUrl;
  final String bearerToken;
  final Future<String?> Function() mediaToken;

  @override
  Future<ResolvedSource> directPlay(String fileId) async {
    final base = '$serverUrl/api/v1/stream/file/$fileId?strategy=DIRECT_PLAY';
    final token = await mediaToken();
    if (token != null) {
      return ResolvedSource(url: '$base&token=$token', headers: const {});
    }
    return ResolvedSource(
      url: base,
      headers: {'Authorization': 'Bearer $bearerToken'},
    );
  }

  @override
  ResolvedSource hls(String sessionId) => ResolvedSource(
        url: '$serverUrl/api/v1/hls/$sessionId/index.m3u8',
        headers: const {},
        probeHeaders: {'Authorization': 'Bearer $bearerToken'},
      );
}
