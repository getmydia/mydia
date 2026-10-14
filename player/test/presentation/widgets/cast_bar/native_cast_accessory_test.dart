import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cast/cast_providers.dart';
import 'package:player/core/cast/cast_session_manager.dart';
import 'package:player/core/platform/native_tab_bar_channel.dart';
import 'package:player/core/remote/ambient_targets.dart';
import 'package:player/domain/models/cast_device.dart';
import 'package:player/native/lib.dart';
import 'package:player/presentation/widgets/cast_bar/cast_bar_state.dart';
import 'package:player/presentation/widgets/cast_bar/dock_extents.dart';
import 'package:player/presentation/widgets/cast_bar/native_cast_accessory.dart';
import 'package:player/presentation/widgets/cast_controls_sheet.dart';
import 'package:player/presentation/widgets/cast_mini_controller.dart';

const _name = 'test/native-tab-bar';
const _channel = MethodChannel(_name);

const _device = CastDevice(
  id: 'd1',
  name: 'Cottage Chromecast',
  protocol: CastProtocolKind.chromecast,
);

CastSession _playing({bool syncing = false, bool paused = false}) =>
    CastSession(
      device: _device,
      mediaInfo: const CastMediaInfo(
        title: 'Silo - S02E01',
        duration: Duration(minutes: 50),
        position: Duration(seconds: 29),
        imageUrl: 'https://art.test/silo.jpg',
      ),
      playbackState:
          paused ? CastPlaybackState.paused : CastPlaybackState.playing,
      isSyncing: syncing,
    );

AmbientTarget _ambient() => AmbientTarget(
      device: const CastDevice(
          id: 'node-tv', name: 'node-tv', protocol: CastProtocolKind.mydia),
      snapshot: FlutterPlaybackSnapshot(
        state: FlutterPlaybackState.playing,
        title: 'Night Harbor',
        imageUrl: 'https://art.test/harbor.jpg',
        positionMs: BigInt.zero,
        durationMs: BigInt.from(6000000),
        muted: false,
        audioTracks: const [],
        subtitleTracks: const [],
        capabilities: const FlutterTargetCapabilities(
            volume: true, trackSelection: true, nextPrevious: false),
        sequence: BigInt.one,
      ),
    );

class _RecordingManager implements CastSessionManager {
  final calls = <String>[];

  @override
  Future<void> play() async => calls.add('play');

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('nativeAccessoryFor', () {
    test('nothing to show: no accessory', () {
      expect(nativeAccessoryFor(null), isNull);
    });

    test('ambient', () {
      expect(
        nativeAccessoryFor(
            CastBarAmbient(target: _ambient(), deviceName: 'Lantern Room')),
        const NativeAccessory(
          title: 'Night Harbor',
          subtitle: 'Playing on Lantern Room',
          artwork: 'https://art.test/harbor.jpg',
          symbol: 'tv',
        ),
      );
    });

    test('offline', () {
      expect(
        nativeAccessoryFor(const CastBarOffline(_device)),
        const NativeAccessory(
          title: 'Cottage Chromecast',
          subtitle: 'Not connected',
          symbol: 'airplayvideo',
        ),
      );
    });

    test('connecting', () {
      expect(
        nativeAccessoryFor(const CastBarConnecting(_device)),
        const NativeAccessory(
          title: 'Connecting to Cottage Chromecast…',
          symbol: 'airplayvideo',
        ),
      );
    });

    test('stale', () {
      expect(
        nativeAccessoryFor(CastBarStale(_playing())),
        const NativeAccessory(
          title: 'Silo - S02E01',
          subtitle: 'Lost connection to Cottage Chromecast',
          artwork: 'https://art.test/silo.jpg',
          symbol: 'airplayvideo',
        ),
      );
    });

    test('idle', () {
      expect(
        nativeAccessoryFor(const CastBarIdle(_device)),
        const NativeAccessory(
          title: 'Ready to play on Cottage Chromecast',
          subtitle: 'Connected',
          symbol: 'airplayvideo.circle.fill',
        ),
      );
    });

    test('playing, paused, and syncing', () {
      expect(
        nativeAccessoryFor(CastBarPlaying(_playing())),
        const NativeAccessory(
          title: 'Silo - S02E01',
          subtitle: 'Casting to Cottage Chromecast',
          artwork: 'https://art.test/silo.jpg',
          symbol: 'airplayvideo',
          playing: true,
        ),
      );
      expect(
          nativeAccessoryFor(CastBarPlaying(_playing(paused: true)))?.playing,
          isFalse);
      final syncing =
          nativeAccessoryFor(CastBarPlaying(_playing(syncing: true)));
      expect(syncing?.playing, isNull);
      expect(syncing?.subtitle, 'Reconnecting to Cottage Chromecast…');
    });
  });

  group('NativeCastAccessory', () {
    late List<MethodCall> calls;

    Future<ProviderContainer> pump(
      WidgetTester tester, {
      required CastBarState? state,
      CastSessionManager? manager,
    }) async {
      calls = [];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_channel,
          (call) async {
        calls.add(call);
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, null));

      final container = ProviderContainer(overrides: [
        castBarStateProvider.overrideWithValue(state),
        nativeTabBarChannelProvider.overrideWith((ref) {
          final channel = NativeTabBarChannel(channel: _channel);
          ref.onDispose(channel.dispose);
          return channel;
        }),
        if (manager != null)
          castSessionManagerProvider.overrideWith((ref) async => manager),
      ]);
      addTearDown(container.dispose);

      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: NativeCastAccessory()),
        ),
      ));
      await tester.pump();
      return container;
    }

    Future<void> fromNative(WidgetTester tester, String method) =>
        tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          _name,
          const StandardMethodCodec().encodeMethodCall(MethodCall(method)),
          (_) {},
        );

    testWidgets('sends the accessory for the state', (tester) async {
      await pump(tester, state: const CastBarIdle(_device));
      expect(calls.single.method, 'setAccessory');
      expect((calls.single.arguments as Map)['title'],
          'Ready to play on Cottage Chromecast');
    });

    testWidgets('unmount removes the accessory', (tester) async {
      await pump(tester, state: const CastBarIdle(_device));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(
          '${calls.last.method}:${calls.last.arguments}', 'setAccessory:null');
    });

    testWidgets('play/pause pauses a playing session', (tester) async {
      final manager = _RecordingManager();
      await pump(tester, state: CastBarPlaying(_playing()), manager: manager);
      await fromNative(tester, 'accessoryPlayPause');
      await tester.pump();
      expect(manager.calls, ['pause']);
    });

    testWidgets('a tap opens the cast controls sheet', (tester) async {
      await pump(tester, state: const CastBarIdle(_device));
      await fromNative(tester, 'accessoryTapped');
      await tester.pumpAndSettle();
      expect(find.byType(CastControlsSheet), findsOneWidget);
      expect(find.text('Ready to play on Cottage Chromecast'), findsOneWidget);
    });

    testWidgets("the sheet's controller reports no cast bar extent",
        (tester) async {
      await pump(tester, state: const CastBarIdle(_device));
      await fromNative(tester, 'accessoryTapped');
      await tester.pumpAndSettle();
      final sheetBar = tester.widget<CastMiniController>(find.descendant(
        of: find.byType(CastControlsSheet),
        matching: find.byType(CastMiniController),
      ));
      expect(sheetBar.reportsExtent, isFalse);
      expect(
        find.descendant(
            of: find.byType(CastControlsSheet),
            matching: find.byType(ReportedExtent)),
        findsNothing,
      );
    });

    testWidgets('the sheet closes when there is nothing left to show',
        (tester) async {
      final container = await pump(tester, state: const CastBarIdle(_device));
      await fromNative(tester, 'accessoryTapped');
      await tester.pumpAndSettle();
      expect(find.byType(CastControlsSheet), findsOneWidget);

      container.updateOverrides([
        castBarStateProvider.overrideWithValue(null),
        nativeTabBarChannelProvider.overrideWith((ref) {
          final channel = NativeTabBarChannel(channel: _channel);
          ref.onDispose(channel.dispose);
          return channel;
        }),
      ]);
      await tester.pumpAndSettle();
      expect(find.byType(CastControlsSheet), findsNothing);
    });
  });
}
