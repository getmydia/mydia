import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/platform/native_tab_bar_channel.dart';

const _name = 'test/native-tab-bar';
const _channel = MethodChannel(_name);

const _home = NativeTab(id: 'home', title: 'Home', symbol: 'house.fill');
const _settings = NativeTab(
    id: 'settings', title: 'Settings', symbol: 'gearshape.fill', badge: '1');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> calls;
  late NativeTabBarChannel bar;

  setUp(() {
    calls = [];
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      return null;
    });
    bar = NativeTabBarChannel(channel: _channel);
  });

  tearDown(() {
    bar.dispose();
    messenger.setMockMethodCallHandler(_channel, null);
  });

  Future<void> fromNative(String method, [Object? arguments]) =>
      messenger.handlePlatformMessage(
        _name,
        const StandardMethodCodec()
            .encodeMethodCall(MethodCall(method, arguments)),
        (_) {},
      );

  group('a failed send', () {
    test('is sent again by an identical call', () async {
      var fail = true;
      messenger.setMockMethodCallHandler(_channel, (call) async {
        calls.add(call);
        if (fail) throw PlatformException(code: 'boom');
        return null;
      });
      await bar.setVisible(true);
      await bar.setTabs(const [_home]);
      await bar.select('home');
      await bar.setAccessory(const NativeAccessory(title: 'Cast'));
      expect(calls, hasLength(4));
      fail = false;
      await bar.setVisible(true);
      await bar.setTabs(const [_home]);
      await bar.select('home');
      await bar.setAccessory(const NativeAccessory(title: 'Cast'));
      expect(calls, hasLength(8));
      await bar.setVisible(true);
      expect(calls, hasLength(8));
    });

    test('does not reset a newer value set while it was in flight', () async {
      final first = Completer<void>();
      var n = 0;
      messenger.setMockMethodCallHandler(_channel, (call) async {
        calls.add(call);
        if (n++ == 0) {
          await first.future;
          throw PlatformException(code: 'boom');
        }
        return null;
      });
      final failing = bar.setVisible(true);
      await bar.setVisible(false);
      first.complete();
      await failing;
      await bar.setVisible(false);
      expect(calls.map((c) => c.arguments), [true, false]);
    });
  });

  test('setTabs sends maps and skips an identical list', () async {
    await bar.setTabs(const [_home, _settings]);
    await bar.setTabs(const [_home, _settings]);
    expect(calls, hasLength(1));
    expect(calls.single.method, 'setTabs');
    expect(calls.single.arguments, [
      {
        'id': 'home',
        'title': 'Home',
        'symbol': 'house.fill',
        'badge': null,
        'enabled': true,
      },
      {
        'id': 'settings',
        'title': 'Settings',
        'symbol': 'gearshape.fill',
        'badge': '1',
        'enabled': true,
      },
    ]);
  });

  test('setTabs resends when a badge changes', () async {
    await bar.setTabs(const [_home, _settings]);
    await bar.setTabs(const [
      _home,
      NativeTab(id: 'settings', title: 'Settings', symbol: 'gearshape.fill'),
    ]);
    expect(calls.map((c) => c.method), ['setTabs', 'setTabs']);
  });

  test('select, setVisible and setAccessory skip repeats', () async {
    await bar.select('home');
    await bar.select('home');
    await bar.setVisible(true);
    await bar.setVisible(true);
    const accessory = NativeAccessory(title: 'Night Harbor', playing: true);
    await bar.setAccessory(accessory);
    await bar.setAccessory(accessory);
    await bar.setAccessory(null);
    expect(calls.map((c) => '${c.method}:${c.arguments}'), [
      'select:home',
      'setVisible:true',
      'setAccessory:{title: Night Harbor, subtitle: null, artwork: null, '
          'symbol: null, playing: true}',
      'setAccessory:null',
    ]);
  });

  test('a first setAccessory(null) sends nothing', () async {
    await bar.setAccessory(null);
    expect(calls, isEmpty);
  });

  test('native calls arrive as events; unknown ones are dropped', () async {
    final events = <NativeTabBarEvent>[];
    final sub = bar.events.listen(events.add);
    await fromNative('tabSelected', 'movies');
    await fromNative('insetsChanged', 117);
    await fromNative('accessoryTapped');
    await fromNative('accessoryPlayPause');
    await fromNative('somethingElse', 1);
    await fromNative('tabSelected', 3);
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();

    expect(events, hasLength(4));
    expect((events[0] as NativeTabSelected).id, 'movies');
    expect((events[1] as NativeInsetsChanged).bottom, 117.0);
    expect(events[2], isA<NativeAccessoryTapped>());
    expect(events[3], isA<NativeAccessoryPlayPause>());
  });

  test('a failing native side never throws', () async {
    messenger.setMockMethodCallHandler(_channel, (call) async {
      throw PlatformException(code: 'boom');
    });
    await bar.setVisible(true);
  });

  group('sidebar', () {
    const payload = <String, Object?>{
      'sections': [
        {'id': 'main', 'title': null, 'items': <Object?>[]},
      ],
    };

    test('insetsChanged reads chromeLeading when present', () async {
      final events = <NativeTabBarEvent>[];
      bar.events.listen(events.add);
      await fromNative('insetsChanged',
          {'top': 0.0, 'leading': 0.0, 'bottom': 0.0, 'chromeLeading': 124.0});
      await Future<void>.delayed(Duration.zero);
      expect((events.single as NativeInsetsChanged).insets,
          const NativeInsets(chromeLeading: 124, reportsChrome: true));
    });

    test('chromeLeading defaults to 0 and does not make insets non-zero', () {
      expect(
          NativeInsets.fromChannel({'top': 0.0, 'leading': 0.0, 'bottom': 0.0})
              ?.chromeLeading,
          0);
      expect(const NativeInsets(chromeLeading: 80).isZero, isTrue);
    });

    test('reportsChrome is set only when the key is present', () {
      expect(
          NativeInsets.fromChannel({'top': 0.0, 'leading': 0.0, 'bottom': 0.0})
              ?.reportsChrome,
          isFalse);
      expect(
          NativeInsets.fromChannel({
            'top': 0.0,
            'leading': 0.0,
            'bottom': 0.0,
            'chromeLeading': 0.0
          })?.reportsChrome,
          isTrue);
    });

    test('setSidebar sends once for equal payloads', () async {
      await bar.setSidebar(payload);
      await bar.setSidebar({...payload});
      expect(calls.map((c) => c.method), ['setSidebar']);
    });

    test('setTabs and setSidebar invalidate each other', () async {
      await bar.setSidebar(payload);
      await bar.setTabs(const [_home]);
      await bar.setSidebar(payload);
      await bar.setTabs(const [_home]);
      expect(calls.map((c) => c.method),
          ['setSidebar', 'setTabs', 'setSidebar', 'setTabs']);
    });

    test('clearSelection sends a null select once, until a select', () async {
      await bar.select('home');
      await bar.clearSelection();
      await bar.clearSelection();
      await bar.select('home');
      await bar.clearSelection();
      expect(calls.map((c) => '${c.method}:${c.arguments}'), [
        'select:home',
        'select:null',
        'select:home',
        'select:null',
      ]);
    });

    test('new sidebar or tabs payloads make the selection sendable again',
        () async {
      await bar.setSidebar(const {'a': 1});
      await bar.clearSelection();
      await bar.setSidebar(const {'a': 2});
      await bar.clearSelection();
      await bar.select('home');
      await bar.setTabs(const [_home]);
      await bar.select('home');
      expect(calls.map((c) => '${c.method}:${c.arguments}'), [
        'setSidebar:{a: 1}',
        'select:null',
        'setSidebar:{a: 2}',
        'select:null',
        'select:home',
        'setTabs:[{id: home, title: Home, symbol: house.fill, badge: null, enabled: true}]',
        'select:home',
      ]);
    });

    test('a failed clearSelection is sent again', () async {
      messenger.setMockMethodCallHandler(_channel, (call) async {
        calls.add(call);
        throw PlatformException(code: 'boom');
      });
      await bar.clearSelection();
      await bar.clearSelection();
      expect(calls.map((c) => '${c.method}:${c.arguments}'),
          ['select:null', 'select:null']);
    });

    test('insetsChanged reads a map', () async {
      final events = <NativeTabBarEvent>[];
      bar.events.listen(events.add);
      await fromNative(
          'insetsChanged', {'top': 50.0, 'leading': 320.0, 'bottom': 20.0});
      await Future<void>.delayed(Duration.zero);
      final event = events.single as NativeInsetsChanged;
      expect(
          event.insets, const NativeInsets(top: 50, leading: 320, bottom: 20));
      expect(event.bottom, 20);
    });

    test('insetsChanged still reads a bare bottom', () async {
      final events = <NativeTabBarEvent>[];
      bar.events.listen(events.add);
      await fromNative('insetsChanged', 83.0);
      await Future<void>.delayed(Duration.zero);
      expect((events.single as NativeInsetsChanged).insets,
          const NativeInsets(bottom: 83));
    });

    test('layoutChanged becomes an event', () async {
      final events = <NativeTabBarEvent>[];
      bar.events.listen(events.add);
      await fromNative('layoutChanged', {'sidebar': false});
      await Future<void>.delayed(Duration.zero);
      expect((events.single as NativeLayoutChanged).sidebar, isFalse);
    });

    test('queryLayout answers the native value, null on failure', () async {
      messenger.setMockMethodCallHandler(_channel,
          (call) async => call.method == 'layout' ? {'sidebar': true} : null);
      expect(await bar.queryLayout(), isTrue);
      messenger.setMockMethodCallHandler(
          _channel, (call) async => throw PlatformException(code: 'x'));
      expect(await bar.queryLayout(), isNull);
    });
  });
}
