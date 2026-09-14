import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:player/presentation/screens/player/subtitle_content_query.dart';

import '../../../test_utils/stub_graphql_client.dart';

/// Answers after [delay], the way a server extracting an embedded track does.
class _SlowLink extends Link {
  _SlowLink(this.delay);

  final Duration delay;

  @override
  Stream<Response> request(Request request, [NextLink? forward]) async* {
    await Future<void>.delayed(delay);
    yield const Response(
      data: {'__typename': 'RootQueryType', 'subtitleContent': 'WEBVTT\n'},
      response: <String, dynamic>{},
    );
  }
}

void main() {
  test('waits out an extraction slower than graphql\'s 5 s default', () {
    fakeAsync((async) {
      // 10.7 s is what extracting one ASS track from a 2.4 GB 4K episode
      // took on a real server.
      final client = stubClient(_SlowLink(const Duration(milliseconds: 10700)));
      QueryResult? result;

      client
          .query(
              subtitleContentQueryOptions(mediaFileId: 'file-1', trackId: '4'))
          .then((r) => result = r);
      async.elapse(const Duration(seconds: 11));

      expect(result, isNotNull);
      expect(result!.exception, isNull);
      expect(result!.data?['subtitleContent'], 'WEBVTT\n');
    });
  });
}
