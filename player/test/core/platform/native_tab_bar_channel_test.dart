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
}
