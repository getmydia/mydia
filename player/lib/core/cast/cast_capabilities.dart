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

  const CastCapabilities.web() : chromecast = false, dlna = false;

  const CastCapabilities.iOS() : chromecast = true, dlna = false;

  const CastCapabilities.full() : chromecast = true, dlna = true;

  /// Whether any casting is possible at all.
  bool get any => chromecast || dlna;

  factory CastCapabilities.forCurrentPlatform() {
    if (PlatformFeatures.isWeb) return const CastCapabilities.web();
    if (PlatformFeatures.isIOS) return const CastCapabilities.iOS();
    return const CastCapabilities.full();
  }
}
