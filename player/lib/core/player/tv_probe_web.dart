/// Web half of the television probe.
///
/// Always false. A browser has no leanback feature to report, and the web
/// player is never the build running on a Chromecast. Exists so the
/// conditional import in `input_capabilities.dart` has a target that compiles
/// on a build with no `dart:io`, mirroring `input_capabilities_web.dart`.
library;

Future<bool> probeLeanback() async => false;
