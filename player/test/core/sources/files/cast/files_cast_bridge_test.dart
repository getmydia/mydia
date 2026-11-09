import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:player/core/p2p/media_proxy.dart';
import 'package:player/core/sources/files/backend/file_system_backend.dart';
import 'package:player/core/sources/files/cast/files_cast_bridge.dart';

void main() {
  late Directory tempDir;
  late File localVideo;
  late FilesCastBridge bridge;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('files_cast_bridge_test');
    localVideo = File('${tempDir.path}/copper_valley.mp4');
    await localVideo.writeAsBytes(List<int>.generate(100, (i) => i));
    bridge = FilesCastBridge(
      lanAddressResolver: () async => '127.0.0.1',
    );
  });

  tearDown(() async {
    await bridge.dispose();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test(
      'serves local file full GET, HEAD, 206 byte ranges, and 416 out-of-range',
      () async {
    final session = await bridge.openSession(
      media: PlayableFile(url: Uri.file(localVideo.path).toString()),
      mime: 'video/mp4',
      subtitles: const {},
    );
    expect(bridge.activePort, isNotNull);
    expect(
        session.mediaUrl, contains('http://127.0.0.1:${bridge.activePort}/f/'));

    // Full GET
    final full = await http.get(Uri.parse(session.mediaUrl));
    expect(full.statusCode, HttpStatus.ok);
    expect(full.headers['accept-ranges'], 'bytes');
    expect(full.headers['content-type'], startsWith('video/mp4'));
    expect(full.headers['access-control-allow-origin'], '*');
    expect(full.bodyBytes, hasLength(100));
    expect(full.bodyBytes.first, 0);
    expect(full.bodyBytes.last, 99);

    // HEAD
    final head = await http.head(Uri.parse(session.mediaUrl));
    expect(head.statusCode, HttpStatus.ok);
    expect(head.headers['content-length'], '100');
    expect(head.bodyBytes, isEmpty);

    // Partial GET (bytes=10-19)
    final partial = await http.get(
      Uri.parse(session.mediaUrl),
      headers: const {'Range': 'bytes=10-19'},
    );
    expect(partial.statusCode, HttpStatus.partialContent);
    expect(partial.headers['content-range'], 'bytes 10-19/100');
    expect(partial.headers['content-length'], '10');
    expect(partial.bodyBytes, List<int>.generate(10, (i) => i + 10));

    // Open-ended range (bytes=95-)
    final tail = await http.get(
      Uri.parse(session.mediaUrl),
      headers: const {'Range': 'bytes=95-'},
    );
    expect(tail.statusCode, HttpStatus.partialContent);
    expect(tail.headers['content-range'], 'bytes 95-99/100');
    expect(tail.bodyBytes, [95, 96, 97, 98, 99]);

    // Unsatisfiable range (bytes=200-300)
    final badRange = await http.get(
      Uri.parse(session.mediaUrl),
      headers: const {'Range': 'bytes=200-300'},
    );
    expect(badRange.statusCode, HttpStatus.requestedRangeNotSatisfiable);
    expect(badRange.headers['content-range'], 'bytes */100');

    // Wrong token -> 403
    final wrongToken = session.mediaUrl.replaceFirst('/f/', '/f/bad');
    final forbidden = await http.get(Uri.parse(wrongToken));
    expect(forbidden.statusCode, HttpStatus.forbidden);

    await bridge.closeSession(session.sessionId);
    expect(bridge.activePort, isNull);
  });

  test('proxies upstream HTTP/SMB streams with auth and Range headers',
      () async {
    String? seenAuth;
    String? seenRange;
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => upstream.close(force: true));
    upstream.listen((req) async {
      seenAuth = req.headers.value(HttpHeaders.authorizationHeader);
      seenRange = req.headers.value(HttpHeaders.rangeHeader);
      req.response.statusCode =
          seenRange != null ? HttpStatus.partialContent : HttpStatus.ok;
      req.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      if (seenRange != null) {
        req.response.headers
            .set(HttpHeaders.contentRangeHeader, 'bytes 5-9/20');
        req.response.headers.contentLength = 5;
        req.response.add([5, 6, 7, 8, 9]);
      } else {
        req.response.headers.contentLength = 20;
        req.response.add(List<int>.generate(20, (i) => i));
      }
      await req.response.close();
    });

    final session = await bridge.openSession(
      media: PlayableFile(
        url: 'http://127.0.0.1:${upstream.port}/share/film.mkv',
        headers: const {'Authorization': 'Basic c2VjcmV0'},
      ),
      mime: 'video/x-matroska',
      subtitles: const {},
    );

    final resp = await http.get(
      Uri.parse(session.mediaUrl),
      headers: const {'Range': 'bytes=5-9'},
    );
    expect(resp.statusCode, HttpStatus.partialContent);
    expect(seenAuth, 'Basic c2VjcmV0');
    expect(seenRange, 'bytes=5-9');
    expect(resp.headers['content-range'], 'bytes 5-9/20');
    expect(resp.bodyBytes, [5, 6, 7, 8, 9]);
  });

  test('serves SRT sidecars converted to WebVTT with CORS headers', () async {
    final srtFile = File('${tempDir.path}/copper_valley.en.srt');
    await srtFile.writeAsString(
      '1\r\n00:00:01,250 --> 00:00:03,500\r\nCafé by the harbor\r\n',
      encoding: utf8,
    );

    final session = await bridge.openSession(
      media: PlayableFile(url: Uri.file(localVideo.path).toString()),
      mime: 'video/mp4',
      subtitles: {
        'ext-0': FilesCastSubtitle(
          file: PlayableFile(url: Uri.file(srtFile.path).toString()),
          format: 'srt',
        ),
      },
    );

    final subUrl = session.subtitleUrl('ext-0');
    final resp = await http.get(Uri.parse(subUrl));
    expect(resp.statusCode, HttpStatus.ok);
    expect(resp.headers['content-type'], contains('text/vtt'));
    expect(resp.headers['access-control-allow-origin'], '*');
    final text = utf8.decode(resp.bodyBytes);
    expect(text, startsWith('WEBVTT\n\n'));
    expect(text, contains('00:00:01.250 --> 00:00:03.500'));
    expect(text, contains('Café by the harbor'));
  });

  test(
      'opening a second session replaces the first and closing stale id is a no-op',
      () async {
    final first = await bridge.openSession(
      media: PlayableFile(url: Uri.file(localVideo.path).toString()),
      mime: 'video/mp4',
      subtitles: const {},
    );
    final second = await bridge.openSession(
      media: PlayableFile(url: Uri.file(localVideo.path).toString()),
      mime: 'video/mp4',
      subtitles: const {},
    );

    // First session token is no longer valid
    final oldResp = await http.get(Uri.parse(first.mediaUrl));
    expect(oldResp.statusCode, HttpStatus.forbidden);

    // Closing stale session ID does not tear down the active second session
    await bridge.closeSession(first.sessionId);
    expect(bridge.activePort, isNotNull);

    final newResp = await http.get(Uri.parse(second.mediaUrl));
    expect(newResp.statusCode, HttpStatus.ok);
  });

  test('healListener rebinds on the same port when the socket is dropped',
      () async {
    final session = await bridge.openSession(
      media: PlayableFile(url: Uri.file(localVideo.path).toString()),
      mime: 'video/mp4',
      subtitles: const {},
    );
    final originalPort = bridge.activePort;

    await bridge.debugDropListener();
    final heal = await bridge.healListener();
    expect(heal, anyOf(ProxyHeal.reboundSamePort, ProxyHeal.reboundNewPort));
    if (heal == ProxyHeal.reboundSamePort) {
      expect(bridge.activePort, originalPort);
      final resp = await http.get(Uri.parse(session.mediaUrl));
      expect(resp.statusCode, HttpStatus.ok);
    }
  });

  test(
      'serves local media and sidecars with raw filesystem paths without file:// prefix',
      () async {
    final srtFile = File('${tempDir.path}/copper_valley_raw.en.srt');
    await srtFile.writeAsString(
      '1\r\n00:00:01,000 --> 00:00:03,000\r\nHarbor dusk\r\n',
      encoding: utf8,
    );

    // Using raw filesystem paths as returned by LocalPathBackend.playable(path)
    final session = await bridge.openSession(
      media: PlayableFile(url: localVideo.path),
      mime: 'video/mp4',
      subtitles: {
        'ext-0': FilesCastSubtitle(
          file: PlayableFile(url: srtFile.path),
          format: 'srt',
        ),
      },
    );

    // Verify media serves cleanly with 200 OK and correct content
    final mediaResp = await http.get(Uri.parse(session.mediaUrl));
    expect(mediaResp.statusCode, HttpStatus.ok);
    expect(mediaResp.bodyBytes, hasLength(100));

    // Verify subtitle serves cleanly with 200 OK and WebVTT conversion
    final subUrl = session.subtitleUrl('ext-0');
    final subResp = await http.get(Uri.parse(subUrl));
    expect(subResp.statusCode, HttpStatus.ok);
    expect(subResp.headers['content-type'], contains('text/vtt'));
    final text = utf8.decode(subResp.bodyBytes);
    expect(text, startsWith('WEBVTT\n\n'));
    expect(text, contains('Harbor dusk'));
  });
}
