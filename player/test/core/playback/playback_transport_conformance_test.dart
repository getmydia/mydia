import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/playback/playback_controller.dart';
import 'package:player/core/playback/playback_transport.dart';
import 'package:player/core/playback/server_features.dart';
import 'package:player/core/playback/stream_urls.dart';
import 'package:player/core/player/progress_reporter.dart';
import 'package:player/core/player/progress_service.dart';

import '../../test_utils/stub_graphql_client.dart';

class _NoUrls implements StreamUrls {
  @override
  Future<ResolvedSource> directPlay(String fileId) =>
      throw UnimplementedError();
  @override
  ResolvedSource hls(String sessionId) => throw UnimplementedError();
  @override
  ResolvedSource hlsFile(String sessionId, String name) =>
      throw UnimplementedError();
}

void main() {
  test('the Mydia transport and progress service fit the seams', () {
    final controller = PlaybackController(
      client: () => null,
      urls: _NoUrls(),
      features: ServerFeatures(),
      relayed: false,
    );
    expect(controller, isA<PlaybackTransport>());
    expect(ProgressService(stubClient(StubLink.responses(const [{}]))),
        isA<ProgressReporter>());
  });
}
