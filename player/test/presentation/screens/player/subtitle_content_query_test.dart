import 'dart:async';

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

/// Runs the SubtitleContent query against a link answering after [delay],
/// and advances the fake clock by [wait].
QueryResult? _query({required Duration delay, required Duration wait}) {
  QueryResult? result;
  fakeAsync((async) {
    stubClient(_SlowLink(delay))
        .query(subtitleContentQueryOptions(mediaFileId: 'file-1', trackId: '4'))
        .then((r) => result = r);
    async.elapse(wait);
  });
  return result;
}

void main() {
  test('waits out an extraction slower than graphql\'s 5 s default', () {
    // 10.7 s is what extracting one ASS track from a 2.4 GB 4K episode took
    // on a real server.
    final result = _query(
      delay: const Duration(milliseconds: 10700),
      wait: const Duration(seconds: 11),
    );

    expect(result, isNotNull);
    expect(result!.exception, isNull);
    expect(result.data?['subtitleContent'], 'WEBVTT\n');
  });

  test('still gives up once kSubtitleContentTimeout has passed', () {
    // The answer never arrives inside the window: graphql's QueryManager
    // throws on a response that lands after its own timeout fired.
    final result = _query(
      delay: kSubtitleContentTimeout * 2,
      wait: kSubtitleContentTimeout + const Duration(seconds: 1),
    );

    expect(result, isNotNull);
    final linkException = result!.exception?.linkException;
    expect(linkException, isA<UnknownException>());
    expect(
      (linkException! as UnknownException).originalException,
      isA<TimeoutException>(),
    );
  });
}
