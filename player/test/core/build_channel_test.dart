import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/build_channel.dart';

void main() {
  group('BuildChannel.resolve', () {
    test('maps each define to its channel', () {
      expect(BuildChannel.resolve('stable', debug: false), BuildChannel.stable);
      expect(BuildChannel.resolve('beta', debug: false), BuildChannel.beta);
      expect(BuildChannel.resolve('dev', debug: false), BuildChannel.dev);
    });

    test('an explicit define wins over debug mode', () {
      expect(BuildChannel.resolve('stable', debug: true), BuildChannel.stable);
    });

    test('empty or unknown falls back to dev in debug, stable otherwise', () {
      expect(BuildChannel.resolve('', debug: true), BuildChannel.dev);
      expect(BuildChannel.resolve('', debug: false), BuildChannel.stable);
      expect(BuildChannel.resolve('rc', debug: false), BuildChannel.stable);
    });
  });

  test('appName and badgeLabel per channel', () {
    expect(BuildChannel.stable.appName, 'Mydia Player');
    expect(BuildChannel.beta.appName, 'Mydia Player Beta');
    expect(BuildChannel.dev.appName, 'Mydia Player Dev');
    expect(BuildChannel.stable.badgeLabel, isNull);
    expect(BuildChannel.beta.badgeLabel, 'BETA');
    expect(BuildChannel.dev.badgeLabel, 'DEV');
  });
}
