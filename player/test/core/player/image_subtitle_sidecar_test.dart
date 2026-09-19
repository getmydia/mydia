import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/image_subtitle_sidecar.dart';

void main() {
  final url = Uri.parse('http://127.0.0.1:1/hls/s1/subs_3.mks');
  const headers = {'Authorization': 'Bearer t'};

  /// Runs a poll against [responses], one per request, on a fake clock that
  /// only moves when the poll waits.
  Future<SidecarFetch> run(
    List<SidecarResponse> responses, {
    List<Duration>? waits,
    bool Function()? cancelled,
    Duration limit = kImageSidecarTimeLimit,
  }) {
    var next = 0;
    var clock = DateTime(2026);
    return pollImageSidecar(
      url: url,
      headers: headers,
      get: (u, h) async {
        expect(u, url);
        expect(h, headers);
        return responses[next++];
      },
      save: (bytes) async => '/tmp/saved-${bytes.length}',
      cancelled: cancelled ?? () => false,
      wait: (delay) async {
        waits?.add(delay);
        clock = clock.add(delay);
      },
      now: () => clock,
      limit: limit,
    );
  }

  group('pollImageSidecar', () {
    test('waits out 503s, then saves the file', () async {
      final waits = <Duration>[];
      final result = await run([
        const SidecarResponse(status: 503, retryAfter: Duration(seconds: 3)),
        const SidecarResponse(status: 503),
        const SidecarResponse(status: 200, body: [1, 2, 3]),
      ], waits: waits);

      expect(
        result,
        isA<SidecarReady>().having((r) => r.path, 'path', '/tmp/saved-3'),
      );
      expect(waits, const [Duration(seconds: 3), Duration(seconds: 2)]);
    });

    test('a 404 is a server that cannot serve bitmap sidecars', () async {
      expect(
        await run([const SidecarResponse(status: 404)]),
        isA<SidecarUnsupported>(),
      );
    });

    test('a 415 is a failed copy', () async {
      expect(
        await run([const SidecarResponse(status: 415)]),
        isA<SidecarFailed>(),
      );
    });

    test('gives up once the next wait would pass the limit', () async {
      final result = await run(
        List.filled(10, const SidecarResponse(status: 503)),
        limit: const Duration(seconds: 5),
      );
      expect(result, isA<SidecarFailed>());
    });

    test('a newer pick cancels the poll without saving', () async {
      var checks = 0;
      final result = await run(
        [
          const SidecarResponse(status: 503),
          const SidecarResponse(status: 200, body: [1]),
        ],
        cancelled: () => checks++ >= 2,
      );
      expect(result, isA<SidecarCancelled>());
    });

    test('a request that throws is a failure', () async {
      final result = await pollImageSidecar(
        url: url,
        headers: headers,
        get: (_, __) async => throw StateError('connection reset'),
        save: (_) async => fail('nothing to save'),
        cancelled: () => false,
      );
      expect(result, isA<SidecarFailed>());
    });
  });

  group('parseRetryAfter', () {
    test('reads seconds, clamped to 1-10', () {
      expect(parseRetryAfter('3'), const Duration(seconds: 3));
      expect(parseRetryAfter(' 30 '), const Duration(seconds: 10));
      expect(parseRetryAfter('0'), const Duration(seconds: 1));
    });

    test('ignores an HTTP-date or nothing', () {
      expect(parseRetryAfter('Wed, 21 Oct 2015 07:28:00 GMT'), isNull);
      expect(parseRetryAfter(null), isNull);
    });
  });

  test('names the sidecar the way the server serves it', () {
    expect(imageSidecarName('3'), 'subs_3.mks');
  });
}
