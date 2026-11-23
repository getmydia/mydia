import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/window/mac_window_channel.dart';
import 'package:player/core/window/window_controller_native.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannel = MethodChannel('test/window');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> calls;
  late Future<Object?> Function(MethodCall call) handler;
  late MacWindowChannel channel;
  late MacWindowChannelController controller;

  setUp(() {
    calls = [];
    handler = (_) async => null;
    messenger.setMockMethodCallHandler(methodChannel, (call) {
      calls.add(call);
      return handler(call);
    });
    channel = MacWindowChannel(channel: methodChannel);
    controller = MacWindowChannelController(channel);
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(methodChannel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('getBounds decodes the top-left rect', () async {
    handler = (_) async => {
      'x': 10.0,
      'y': 20.0,
      'width': 800.0,
      'height': 600.0,
    };

    expect(await controller.getBounds(), const Rect.fromLTWH(10, 20, 800, 600));
    expect(calls.single.method, 'getBounds');
  });

  test('setBounds and setAspectRatio send the spec shapes', () async {
    await controller.setBounds(const Rect.fromLTWH(1, 2, 3, 4));
    await controller.setAspectRatio(0);
    await controller.setMinimumSize(const Size(640, 360));

    expect(calls[0].method, 'setBounds');
    expect(calls[0].arguments, {
      'x': 1.0,
      'y': 2.0,
      'width': 3.0,
      'height': 4.0,
    });
    expect(calls[1].method, 'setAspectRatio');
    expect(calls[1].arguments, {'ratio': 0.0});
    expect(calls[2].method, 'setMinimumSize');
    expect(calls[2].arguments, {'width': 640.0, 'height': 360.0});
  });

  test('state queries map to the same-named methods', () async {
    handler = (call) async => call.method == 'isFullScreen';

    expect(await controller.isFullScreen(), isTrue);
    expect(await controller.isMaximized(), isFalse);
    await controller.maximize();
    await controller.unmaximize();
    await controller.minimize();
    await controller.close();
    await controller.startDragging();

    expect(calls.map((c) => c.method), [
      'isFullScreen',
      'isMaximized',
      'maximize',
      'unmaximize',
      'minimize',
      'close',
      'startDragging',
    ]);
  });

  test('a null state reply reads as false', () async {
    expect(await controller.isFullScreen(), isFalse);
    expect(await controller.isMaximized(), isFalse);
  });

  test('a no_window error fails the future', () async {
    handler = (_) async => throw PlatformException(code: 'no_window');

    await expectLater(
      controller.isFullScreen(),
      throwsA(isA<PlatformException>()),
    );
  });

  test(
    'getWorkAreas decodes, skips empty areas, and is [] on failure',
    () async {
      handler = (_) async => [
        {
          'x': 0.0,
          'y': 0.0,
          'width': 1440.0,
          'height': 875.0,
          'isPrimary': true,
        },
        {
          'x': 1440.0,
          'y': 0.0,
          'width': 0.0,
          'height': 0.0,
          'isPrimary': false,
        },
      ];

      final areas = await channel.getWorkAreas();
      expect(areas.single.bounds, const Rect.fromLTWH(0, 0, 1440, 875));
      expect(areas.single.isPrimary, isTrue);

      handler = (_) async => throw PlatformException(code: 'no_window');
      expect(await channel.getWorkAreas(), isEmpty);
    },
  );

  test('listen delivers pushed events with their arguments', () async {
    final events = <(String, Map<Object?, Object?>?)>[];
    channel.listen((event, args) => events.add((event, args)));

    await messenger.handlePlatformMessage(
      methodChannel.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('restored', {'maximized': true}),
      ),
      (_) {},
    );

    expect(events, hasLength(1));
    expect(events.single.$1, 'restored');
    expect(events.single.$2, {'maximized': true});
  });

  test('nativeWindowController picks the channel on macOS only', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    expect(useMacWindowChannel, isTrue);
    expect(nativeWindowController(), isA<MacWindowChannelController>());

    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    expect(useMacWindowChannel, isFalse);
    expect(nativeWindowController(), isA<WindowManagerController>());
  });
}
