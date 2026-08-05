import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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

  test('betaChannelEnabled returns what the host reports', () async {
    mock((_) async => true);

    expect(await MacOSUpdater.betaChannelEnabled(), isTrue);
    expect(calls.map((c) => c.method), ['getBetaChannel']);
  });

  test('betaChannelEnabled defaults to false when the host returns null',
      () async {
    mock((_) async => null);

    expect(await MacOSUpdater.betaChannelEnabled(), isFalse);
  });

  test('setBetaChannel forwards the boolean', () async {
    await MacOSUpdater.setBetaChannel(true);

    expect(calls.single.method, 'setBetaChannel');
    expect(calls.single.arguments, isTrue);
  });

  test('a host failure never propagates to the caller', () async {
    // The updater is called from settings taps. A PlatformException escaping
    // here would surface as an unhandled error in the widget tree.
    mock((_) async => throw PlatformException(code: 'boom'));

    await expectLater(MacOSUpdater.checkForUpdates(), completes);
    await expectLater(MacOSUpdater.setBetaChannel(true), completes);
    expect(await MacOSUpdater.betaChannelEnabled(), isFalse);
  });

  test('setBetaChannel reports success', () async {
    expect(await MacOSUpdater.setBetaChannel(true), isTrue);
  });

  test('setBetaChannel reports failure when the host errors', () async {
    mock((_) async => throw PlatformException(code: 'boom'));

    expect(await MacOSUpdater.setBetaChannel(true), isFalse);
  });

  test('an unregistered host never propagates', () async {
    // Clearing the handler is what a real macOS build looks like before the
    // native side registers, and MissingPluginException is not a
    // PlatformException, so it needs its own catch clause.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(kSparkleChannel, null);

    await expectLater(MacOSUpdater.checkForUpdates(), completes);
    expect(await MacOSUpdater.betaChannelEnabled(), isFalse);
    expect(await MacOSUpdater.setBetaChannel(true), isFalse);
  });
}
