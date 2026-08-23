import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_flutter/graphql_flutter.dart'
    show HttpLinkHeaders, Operation, Request, Response, gql;
import 'package:player/core/graphql/client.dart';
import 'package:player/core/player/device_profile.dart';

const _profile = DeviceProfile(
  containers: ['mkv'],
  videoCodecs: ['hevc'],
  audioCodecs: ['ac3'],
  hdrFormats: [],
);

Request _request() => Request(
      operation: Operation(
        document: gql('query Movies { movies { id } }'),
        operationName: 'Movies',
      ),
    );

/// Runs [link] once against [request] and returns the headers the
/// terminating link saw, i.e. what would actually have gone out over HTTP.
Future<Map<String, String>?> _headersSeenBy(
  DeviceProfileLink link,
  Request request,
) async {
  Map<String, String>? seen;
  await link.request(request, (forwarded) {
    seen = forwarded.context.entry<HttpLinkHeaders>()?.headers;
    return Stream.value(const Response(data: {}, response: {}));
  }).first;
  return seen;
}

void main() {
  group('DeviceProfileLink', () {
    test('a request issued before the profile resolves carries no header',
        () async {
      final link = DeviceProfileLink(getDeviceProfile: () => null);

      final headers = await _headersSeenBy(link, _request());

      expect(headers?[DeviceProfile.headerName], isNull);
    });

    test('a request issued once the profile is available carries it', () async {
      final link = DeviceProfileLink(getDeviceProfile: () => _profile);

      final headers = await _headersSeenBy(link, _request());

      expect(headers?[DeviceProfile.headerName], _profile.toHeaderValue());
    });

    test(
        'the same link, unchanged, answers differently before and after the '
        'probe resolves', () async {
      // Models DeviceProfileHolder: a single mutable slot the link reads
      // fresh on every request, exactly like production wires it through
      // graphql_provider.dart. No client is rebuilt between these two calls.
      DeviceProfile? current;
      final link = DeviceProfileLink(getDeviceProfile: () => current);

      final beforeProbe = await _headersSeenBy(link, _request());
      expect(beforeProbe?[DeviceProfile.headerName], isNull);

      current = _profile;

      final afterProbe = await _headersSeenBy(link, _request());
      expect(afterProbe?[DeviceProfile.headerName], _profile.toHeaderValue());
    });

    test('preserves a header already attached earlier in the link chain',
        () async {
      final link = DeviceProfileLink(getDeviceProfile: () => _profile);
      final requestWithAuth = _request().updateContextEntry<HttpLinkHeaders>(
        (_) => const HttpLinkHeaders(headers: {'Authorization': 'Bearer tok'}),
      );

      final headers = await _headersSeenBy(link, requestWithAuth);

      expect(headers?['Authorization'], 'Bearer tok');
      expect(headers?[DeviceProfile.headerName], _profile.toHeaderValue());
    });
  });
}
