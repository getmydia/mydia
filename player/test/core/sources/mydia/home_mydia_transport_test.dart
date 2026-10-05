import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphql/client.dart';
import 'package:player/core/sources/mydia/home_mydia_browse.dart';
import 'package:player/core/sources/mydia/home_mydia_transport.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/sources/source_error.dart';

class _Link extends Link {
  _Link(this.answer);
  final Response Function(Request) answer;
  final requests = <Request>[];
  @override
  Stream<Response> request(Request request, [NextLink? forward]) {
    requests.add(request);
    return Stream.value(answer(request));
  }
}

class _Absent extends MydiaPresenceNotifier {
  @override
  bool build() => false;
}

GraphQLClient _client(_Link link) =>
    GraphQLClient(link: link, cache: GraphQLCache(store: InMemoryStore()));

Response _data(Map<String, dynamic> data) =>
    Response(data: data, response: const {});

void main() {
  test('a query answers its data', () async {
    final link = _Link((_) => _data({
          'movies': {'totalCount': 0}
        }));
    final t = HomeMydiaTransport(() async => _client(link));
    final data = await t.send(
        'query GuestMovies(\$first: Int) { movies(first: \$first) { totalCount } }',
        {'first': 2});
    expect(data['movies'], {'totalCount': 0});
    expect(link.requests.single.variables, {'first': 2});
  });

  test('a mutation goes through mutate', () async {
    final link = _Link((_) => _data({'removeFromContinueWatching': true}));
    final t = HomeMydiaTransport(() async => _client(link));
    await t.send(
        'mutation Remove(\$id: ID!) { removeFromContinueWatching(mediaItemId: \$id) }',
        {'id': 'm-1'});
    expect(link.requests.single.operation.document.definitions, isNotEmpty);
  });

  test('an auth error is unauthorized, another error is server', () async {
    final auth = HomeMydiaTransport(() async => _client(_Link((_) =>
        const Response(
            errors: [GraphQLError(message: 'unauthorized')], response: {}))));
    await expectLater(
        auth.send('query Q { a }', const {}),
        throwsA(isA<SourceException>()
            .having((e) => e.kind, 'kind', SourceErrorKind.unauthorized)));
    final other = HomeMydiaTransport(() async => _client(_Link((_) =>
        const Response(
            errors: [GraphQLError(message: 'boom')], response: {}))));
    await expectLater(
        other.send('query Q { a }', const {}),
        throwsA(isA<SourceException>()
            .having((e) => e.kind, 'kind', SourceErrorKind.server)));
  });

  test('no client is unreachable', () async {
    final t =
        HomeMydiaTransport(() async => throw Exception('Not authenticated'));
    await expectLater(
        t.send('query Q { a }', const {}),
        throwsA(isA<SourceException>()
            .having((e) => e.kind, 'kind', SourceErrorKind.unreachable)));
  });

  test('no home Mydia means no browse source', () {
    final container = ProviderContainer(
        overrides: [mydiaPresentProvider.overrideWith(_Absent.new)]);
    addTearDown(container.dispose);
    expect(container.read(homeMydiaBrowseSourceProvider), isNull);
  });
}
