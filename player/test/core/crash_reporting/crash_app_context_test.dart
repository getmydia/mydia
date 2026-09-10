import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/crash_reporting/crash_app_context.dart';

void main() {
  test('platform names match DeviceInfoService.getPlatform', () {
    expect(crashPlatformName(TargetPlatform.android), 'android');
    expect(crashPlatformName(TargetPlatform.iOS), 'ios');
    expect(crashPlatformName(TargetPlatform.macOS), 'macos');
    expect(crashPlatformName(TargetPlatform.windows), 'windows');
    expect(crashPlatformName(TargetPlatform.linux), 'linux');
  });

  test('environment follows the build mode, as the server names it', () {
    expect(crashEnvironment(release: true, profile: false), 'prod');
    expect(crashEnvironment(release: false, profile: true), 'profile');
    expect(crashEnvironment(release: false, profile: false), 'dev');
  });
}
