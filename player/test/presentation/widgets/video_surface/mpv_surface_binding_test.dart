// MpvSurfaceBinding's attach and detach against a scripted plugin: a detach
// must cancel whatever attach is still waiting, and must not wait forever on
// a native reply.
//
// `AppKitView` asks the engine for a view over
// `SystemChannels.platform_views`, which is mocked here to accept it.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:player/core/player/mpv_surface_channel.dart';
import 'package:player/core/player/subtitle_size.dart';
import 'package:player/core/player/video_scaling.dart';
import 'package:player/presentation/widgets/video_surface/player_video_surface.dart';

class _Surface implements MpvSurface {
  /// Completes [attach] when set; otherwise it returns at once.
  Completer<void>? attachGate;

  /// Completes [detach] when set; otherwise it returns at once.
  Completer<void>? detachGate;

  final setOptions = <(int, String, String)>[];
  final detached = <int>[];
  final attached = <int>[];

  @override
  Future<void> attach(int handle, int viewId) async {
    attached.add(handle);
    await attachGate?.future;
  }

  @override
  Future<VideoOutputStart> awaitVideoOutput(int handle) async =>
      VideoOutputStart.started;

  @override
  Future<void> setOption(int handle, String name, String value) async {
    setOptions.add((handle, name, value));
  }

  @override
  Future<void> detach(int handle) async {
    detached.add(handle);
    await detachGate?.future;
  }

  @override
  Stream<DisplayInfo> get display => const Stream.empty();
}

class _Player extends PlatformPlayer {
  _Player({int? handle}) : super(configuration: const PlayerConfiguration()) {
    if (handle != null) _handle.complete(handle);
  }

  final _handle = Completer<int>();

  /// Set once something asked for the handle.
  bool handleRequested = false;

  @override
  Future<int> get handle {
    handleRequested = true;
    return _handle.future;
  }

  /// Reports [params] the way mpv's `video-params` observer would.
  void emitVideoParams(VideoParams params) => videoParamsController.add(params);

  @override
  // ignore: must_call_super, the fake has no native player to release.
  Future<void> dispose() async {}
}

Future<MpvSurfaceBinding> _mount(
  WidgetTester tester, {
  required _Surface surface,
  int? handle,
}) async {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform_views,
    (call) async => null,
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform_views,
      null,
    ),
  );
  final binding = MpvSurfaceBinding(
    player: Player(platformPlayer: _Player(handle: handle)),
    surface: surface,
  );
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: PlayerVideoSurface(
        binding: binding,
        scaling: VideoScaling.fit,
        subtitleSize: SubtitleSize.medium,
      ),
    ),
  );
  await tester.pump();
  return binding;
}

void main() {
  testWidgets('detach cancels an attach still waiting for the player handle', (
    tester,
  ) async {
    final surface = _Surface();
    final binding = await _mount(tester, surface: surface);

    bool? attached;
    unawaited(binding.attach().then((v) => attached = v));
    await tester.pump();
    expect(attached, isNull, reason: 'the handle has not resolved');
    expect(
      (binding.player.platform! as _Player).handleRequested,
      isTrue,
      reason: 'attach is past the view and waiting on the handle',
    );

    await binding.detach();
    await tester.pump();

    expect(attached, isFalse);
    expect(surface.detached, isEmpty, reason: 'nothing was attached');
  });

  testWidgets('a detach during the native attach sends no panscan', (
    tester,
  ) async {
    final surface = _Surface()..attachGate = Completer<void>();
    final binding = await _mount(tester, surface: surface, handle: 5);

    bool? attached;
    unawaited(binding.attach().then((v) => attached = v));
    await tester.pump();
    final detaching = binding.detach();
    await tester.pump();
    surface.attachGate!.complete();
    await tester.pump();
    await detaching;

    expect(attached, isFalse);
    expect(surface.detached, [5]);
    expect(
      surface.setOptions,
      isEmpty,
      reason: 'panscan must not follow a detach to a handle on its way out',
    );
  });

  testWidgets('an attach that completes sends the initial panscan', (
    tester,
  ) async {
    final surface = _Surface();
    final binding = await _mount(tester, surface: surface, handle: 6);

    expect(await binding.attach(), isTrue);
    await tester.pump();

    expect(surface.setOptions, [(6, 'panscan', '0.0')]);
  });

  testWidgets('detach completes when the native reply never arrives', (
    tester,
  ) async {
    final surface = _Surface()..detachGate = Completer<void>();
    final binding = await _mount(tester, surface: surface, handle: 7);
    expect(await binding.attach(), isTrue);

    var done = false;
    unawaited(binding.detach().then((_) => done = true));
    await tester.pump(const Duration(seconds: 4));
    expect(done, isFalse, reason: 'the plugin may take its full 3 s');

    await tester.pump(const Duration(seconds: 2));
    expect(done, isTrue);
  });

  group('target-colorspace-hint follows the source gamma', () {
    Future<(MpvSurfaceBinding, _Surface, _Player)> attached(
      WidgetTester tester,
    ) async {
      final surface = _Surface();
      final binding = await _mount(tester, surface: surface, handle: 9);
      expect(await binding.attach(), isTrue);
      await tester.pump();
      surface.setOptions.clear();
      return (binding, surface, binding.player.platform! as _Player);
    }

    Future<void> report(WidgetTester tester, _Player p, String gamma) async {
      p.emitVideoParams(VideoParams(gamma: gamma));
      await tester.pump();
    }

    testWidgets('SDR keeps the attach value and sends nothing', (tester) async {
      final (_, surface, p) = await attached(tester);
      await report(tester, p, 'bt.1886');
      expect(surface.setOptions, isEmpty);
    });

    testWidgets('PQ turns it on once, and SDR after it turns it off', (
      tester,
    ) async {
      final (_, surface, p) = await attached(tester);
      await report(tester, p, 'pq');
      await report(tester, p, 'pq');
      await report(tester, p, 'srgb');
      expect(surface.setOptions, [
        (9, 'target-colorspace-hint', 'yes'),
        (9, 'target-colorspace-hint', 'no'),
      ]);
    });

    testWidgets('an unknown gamma changes nothing', (tester) async {
      final (_, surface, p) = await attached(tester);
      await report(tester, p, 'auto');
      expect(surface.setOptions, isEmpty);
    });

    testWidgets('nothing is sent after a detach', (tester) async {
      final (binding, surface, p) = await attached(tester);
      await binding.detach();
      await report(tester, p, 'hlg');
      expect(surface.setOptions, isEmpty);
    });
  });

  testWidgets('an attach with no native reply gives up, so playback can fall '
      'back', (tester) async {
    final surface = _Surface()..attachGate = Completer<void>();
    final binding = await _mount(tester, surface: surface, handle: 8);

    bool? attached;
    unawaited(binding.attach().then((v) => attached = v));
    await tester.pump(const Duration(seconds: 4));
    expect(attached, isNull);
    expect(surface.attached, [8], reason: 'the native attach was sent');

    await tester.pump(const Duration(seconds: 2));
    expect(attached, isFalse);
    expect(surface.setOptions, isEmpty);
  });
}
