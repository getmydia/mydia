import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/app_menu/app_menu_channel.dart';
import 'package:player/core/app_menu/now_playing.dart';

const _playing = NowPlaying(
  title: 'The Long Aurora',
  isPlaying: true,
  hasNext: false,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('NowPlayingPublisher', () {
    late List<NowPlaying?> sent;
    late NowPlayingPublisher publisher;

    setUp(() {
      sent = [];
      publisher = NowPlayingPublisher((state) async => sent.add(state));
    });

    test('the claimant publishes and clears', () {
      final owner = Object();
      publisher.claim(owner);
      publisher.publish(owner, _playing);
      publisher.clear(owner);

      expect(sent, [_playing, null]);
      expect(publisher.current, isNull);
    });

    test('an identical state is not re-sent', () {
      final owner = Object();
      publisher.claim(owner);
      publisher.publish(owner, _playing);
      publisher.publish(owner, _playing);

      expect(sent, [_playing]);
      expect(publisher.current, _playing);
    });

    test('a superseded owner can neither publish nor clear', () {
      // Flutter mounts the new PlayerScreen before disposing the old one, so
      // the old screen's late clear must not wipe the new screen's state.
      final older = Object();
      final newer = Object();
      publisher.claim(older);
      publisher.claim(newer);
      publisher.publish(newer, _playing);

      publisher.publish(
          older,
          const NowPlaying(
            title: 'Stale',
            isPlaying: false,
            hasNext: false,
          ));
      publisher.clear(older);

      expect(sent, [_playing]);
      expect(publisher.current, _playing);
    });

    test('a new claim clears a state the previous owner left live', () {
      final older = Object();
      publisher.claim(older);
      publisher.publish(older, _playing);
      publisher.claim(Object());

      expect(sent, [_playing, null]);
      expect(publisher.current, isNull);
    });

    test('publishing without a claim is ignored', () {
      publisher.publish(Object(), _playing);

      expect(sent, isEmpty);
      expect(publisher.current, isNull);
    });

    test('a new claimant re-sends even an identical state', () {
      // The dedupe is per claim: after a clear, Swift holds nothing, so the
      // first publish of the next claimant must always reach it.
      final first = Object();
      publisher.claim(first);
      publisher.publish(first, _playing);
      publisher.clear(first);
      final second = Object();
      publisher.claim(second);
      publisher.publish(second, _playing);

      expect(sent, [_playing, null, _playing]);
    });
  });

  group('sendNowPlaying', () {
    late List<MethodCall> calls;

    void mock(Future<Object?> Function(MethodCall call) handler) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(kAppMenuChannel, (call) async {
        calls.add(call);
        return handler(call);
      });
    }

    setUp(() {
      calls = [];
      mock((_) async => null);
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(kAppMenuChannel, null);
    });

    test('a state is sent as setNowPlaying with its wire map', () async {
      await sendNowPlaying(_playing);

      expect(calls.single.method, 'setNowPlaying');
      expect(calls.single.arguments, {
        'title': 'The Long Aurora',
        'isPlaying': true,
        'hasNext': false,
      });
    });

    test('null is sent as clearNowPlaying', () async {
      await sendNowPlaying(null);

      expect(calls.single.method, 'clearNowPlaying');
    });

    test('a host failure never propagates', () async {
      mock((_) async => throw PlatformException(code: 'boom'));

      await expectLater(sendNowPlaying(_playing), completes);
    });

    test('an unregistered host never propagates', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(kAppMenuChannel, null);

      await expectLater(sendNowPlaying(null), completes);
    });
  });
}
