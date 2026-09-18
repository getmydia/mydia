import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/update/update_track.dart';
import 'package:player/core/update/updaters/macos_updater.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> calls;

  void mock(Future<Object?> Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(kSparkleChannel, (call) async {
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
        .setMockMethodCallHandler(kSparkleChannel, null);
  });

  test('checkForUpdates reaches the host', () async {
    await MacOSUpdater.checkForUpdates();

    expect(calls.map((c) => c.method), ['checkForUpdates']);
  });

  test('a host failure never propagates to the caller', () async {
    // The updater is called from settings taps. A PlatformException escaping
    // here would surface as an unhandled error in the widget tree.
    mock((_) async => throw PlatformException(code: 'boom'));

    await expectLater(MacOSUpdater.checkForUpdates(), completes);
    await expectLater(MacOSUpdater.setTrack(UpdateTrack.beta), completes);
    expect(await MacOSUpdater.currentTrack(), UpdateTrack.stable);
  });

  test('an unregistered host never propagates', () async {
    // Clearing the handler is what a real macOS build looks like before the
    // native side registers, and MissingPluginException is not a
    // PlatformException, so it needs its own catch clause.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(kSparkleChannel, null);

    await expectLater(MacOSUpdater.checkForUpdates(), completes);
    expect(await MacOSUpdater.currentTrack(), UpdateTrack.stable);
    expect(await MacOSUpdater.setTrack(UpdateTrack.beta), isFalse);
  });

  test('currentTrack maps the host string', () async {
    mock((_) async => 'beta');

    expect(await MacOSUpdater.currentTrack(), UpdateTrack.beta);
    expect(calls.map((c) => c.method), ['getTrack']);
  });

  test('an unknown host string falls back to stable', () async {
    mock((_) async => 'banana');

    expect(await MacOSUpdater.currentTrack(), UpdateTrack.stable);
  });

  test('setTrack sends the wire name and reports acceptance', () async {
    expect(await MacOSUpdater.setTrack(UpdateTrack.dev), isTrue);

    expect(calls.single.method, 'setTrack');
    expect(calls.single.arguments, 'dev');
  });

  test('a host that is not there reports failure rather than throwing',
      () async {
    // Clearing the handler is what a real macOS build looks like before the
    // native side registers, and MissingPluginException is not a
    // PlatformException, so it needs its own catch clause.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(kSparkleChannel, null);

    expect(await MacOSUpdater.setTrack(UpdateTrack.beta), isFalse);
  });
}
