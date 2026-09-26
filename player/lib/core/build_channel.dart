import 'package:flutter/foundation.dart';

/// Which release channel this binary was built for.
///
/// CI stamps it with `--dart-define=MYDIA_CHANNEL=...` from
/// `tool/apply-channel.sh`. The version string cannot be used instead: iOS
/// strips the prerelease suffix before it reaches PackageInfo.
///
/// This is the build's channel, not the update track the user picked in
/// settings (`UpdateTrack`). A beta build whose user switched to stable stays
/// a beta build until the stable update installs.
enum BuildChannel {
  stable,
  beta,
  dev;

  static const String _define = String.fromEnvironment('MYDIA_CHANNEL');

  static final BuildChannel current = resolve(_define, debug: kDebugMode);

  /// Unknown or missing values never throw. A local `flutter run` has no
  /// define, and reads as dev so it is never mistaken for a release.
  static BuildChannel resolve(String define, {required bool debug}) {
    for (final channel in values) {
      if (channel.name == define) return channel;
    }
    return debug ? dev : stable;
  }

  String get appName => switch (this) {
        stable => 'Mydia Player',
        beta => 'Mydia Player Beta',
        dev => 'Mydia Player Dev',
      };

  String? get badgeLabel => switch (this) {
        stable => null,
        beta => 'BETA',
        dev => 'DEV',
      };
}
