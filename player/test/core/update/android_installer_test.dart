import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/update/android_installer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final calls = <MethodCall>[];
  Object? response;
  Object? error;

  setUp(() {
    calls.clear();
    response = null;
    error = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(kInstallerChannel, (call) async {
      calls.add(call);
      if (error != null) throw error!;
      return response;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(kInstallerChannel, null);
  });

  test('canInstall reports what the host says', () async {
    response = true;
    expect(await AndroidInstaller().canInstall(), isTrue);
    expect(calls.single.method, 'canInstall');
  });

  test('canInstall is false when the host is not there', () async {
    error = MissingPluginException();
    expect(await AndroidInstaller().canInstall(), isFalse);
  });

  test('install sends the path', () async {
    await AndroidInstaller().install('/tmp/mydia.apk');
    expect(calls.single.method, 'install');
    expect(calls.single.arguments, {'path': '/tmp/mydia.apk'});
  });

  test('a denied permission surfaces as its own exception', () async {
    error = PlatformException(code: 'permission_denied', message: 'no');
    expect(
      () => AndroidInstaller().install('/tmp/mydia.apk'),
      throwsA(isA<InstallerPermissionDenied>()),
    );
  });

  test('a missing host surfaces as its own exception', () async {
    error = MissingPluginException();
    expect(
      () => AndroidInstaller().install('/tmp/mydia.apk'),
      throwsA(isA<InstallerUnavailable>()),
    );
  });

  test('any other host failure keeps its message', () async {
    error = PlatformException(code: 'install_failed', message: 'session died');
    expect(
      () => AndroidInstaller().install('/tmp/mydia.apk'),
      throwsA(predicate((e) => e.toString().contains('session died'))),
    );
  });
}
