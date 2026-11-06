import '../player/input_capabilities.dart';
import '../player/platform_features.dart';

/// Which cast protocols this build can actually discover.
///
/// This replaces platform gating, because the answer is per-platform *and*
/// per-entitlement: iOS can discover Chromecast through Apple's Bonjour
/// framework, but DLNA needs SSDP raw multicast, which requires the
/// `com.apple.developer.networking.multicast` entitlement we do not request.
class CastCapabilities {
  final bool chromecast;
  final bool dlna;

  const CastCapabilities({required this.chromecast, required this.dlna});

  const CastCapabilities.none()
      : chromecast = false,
        dlna = false;

  const CastCapabilities.web() : this.none();

  const CastCapabilities.iOS()
      : chromecast = true,
        dlna = false;

  const CastCapabilities.full()
      : chromecast = true,
        dlna = true;

  /// Whether any casting is possible at all.
  bool get any => chromecast || dlna;

  /// Reads [InputCapabilities.directionalPrimary], so it must run after
  /// `InputCapabilities.initialize()`, which `_startApp` awaits before
  /// `runApp`.
  factory CastCapabilities.forCurrentPlatform() => CastCapabilities.forPlatform(
        isWeb: PlatformFeatures.isWeb,
        isIOS: PlatformFeatures.isIOS,
        isTv: InputCapabilities.directionalPrimary,
      );

  /// The capability decision itself, separated from the static platform
  /// lookups so it can be exercised for every platform on one machine. This
  /// is the switch that decides whether iOS shows DLNA devices at all.
  ///
  /// A television (Chromecast with Google TV, any leanback device) is a cast
  /// receiver, so it sends nothing: no cast button, no Chromecast or DLNA
  /// discovery. It can still be cast *to* as a Mydia remote-control target,
  /// which does not go through these capabilities.
  factory CastCapabilities.forPlatform({
    required bool isWeb,
    required bool isIOS,
    required bool isTv,
  }) {
    if (isTv) return const CastCapabilities.none();
    if (isWeb) return const CastCapabilities.web();
    if (isIOS) return const CastCapabilities.iOS();
    return const CastCapabilities.full();
  }
}
