import 'dart:convert';

import 'codec_profile.dart';
import 'device_profile_web.dart'
    if (dart.library.io) 'device_profile_native.dart' as platform;

export 'codec_profile.dart'
    show CodecProfile, ProfileComparison, ProfileCondition, ProfileProperty;

/// What this client can decode, sent to the server on every request.
///
/// Held in memory for the app session and never persisted. A stored profile
/// goes stale the moment the device changes OS, display, or hardware decode
/// availability, which is the failure this design exists to avoid.
class DeviceProfile {
  final List<String> containers;
  final List<String> videoCodecs;
  final List<String> audioCodecs;
  final List<String> hdrFormats;

  /// Per-codec constraints, for the parts a codec name cannot express.
  ///
  /// A codec listed in [videoCodecs] with no entry here is claimed
  /// unconditionally, which is what the flat lists meant on their own. An entry
  /// narrows that claim: "hevc, but only up to 8-bit" is the difference between
  /// a tablet playing its library and a tablet showing "Could not open codec."
  final List<CodecProfile> codecProfiles;

  const DeviceProfile({
    required this.containers,
    required this.videoCodecs,
    required this.audioCodecs,
    required this.hdrFormats,
    this.codecProfiles = const [],
  });

  DeviceProfile copyWith({List<CodecProfile>? codecProfiles}) => DeviceProfile(
        containers: containers,
        videoCodecs: videoCodecs,
        audioCodecs: audioCodecs,
        hdrFormats: hdrFormats,
        codecProfiles: codecProfiles ?? this.codecProfiles,
      );

  /// What browsers decode. Mirrors `DeviceProfile.browser_default/0` on the
  /// server, so a web client asserts nothing the server would not have assumed.
  const DeviceProfile.webDefault()
      : containers = const ['mp4', 'webm', 'm4v'],
        videoCodecs = const [
          'h264',
          'h.264',
          'avc',
          'avc1',
          'vp9',
          'vp09',
          'av1',
          'av01',
        ],
        audioCodecs = const ['aac', 'mp3', 'opus', 'vorbis'],
        hdrFormats = const [],
        // A browser enforces its own codec support at `canPlayType`, and this
        // client has no capability table to read, so it constrains nothing.
        codecProfiles = const [];

  Map<String, dynamic> toJson() => {
        'containers': containers,
        'videoCodecs': videoCodecs,
        'audioCodecs': audioCodecs,
        'hdrFormats': hdrFormats,
        // Omitted entirely when empty. An older server ignores the key either
        // way, but sending nothing keeps the header at the size it has always
        // been for clients with nothing to constrain.
        if (codecProfiles.isNotEmpty)
          'codecProfiles': codecProfiles.map((p) => p.toJson()).toList(),
      };

  /// Unpadded base64url of the JSON, which is what the server's plug decodes.
  String toHeaderValue() {
    final encoded = base64Url.encode(utf8.encode(jsonEncode(toJson())));
    return encoded.replaceAll('=', '');
  }

  static const String headerName = 'X-Mydia-Device-Profile';
}

/// Detects what this client can decode.
///
/// Native platforms probe mpv's decoder list and fall back to a static table
/// on any failure or surprising answer; web reports a fixed browser-decode
/// profile since there is nothing to probe. See `device_profile_native.dart`
/// and `device_profile_web.dart`.
Future<DeviceProfile> detectDeviceProfile() => platform.detectDeviceProfile();

/// A mutable, session-lived slot for the profile [detectDeviceProfile]
/// eventually resolves to.
///
/// GraphQL request links (see `DeviceProfileLink` in `core/graphql/client.dart`)
/// read [profile] fresh on every outgoing request rather than through a
/// watched Riverpod provider. That is deliberate: the probe constructs and
/// initializes a real native player, which is not fast, and the very first
/// requests of a cold start (the home screen's opening queries) must not
/// wait on it or be served by a GraphQL client that gets rebuilt out from
/// under them the moment it settles. A request that races ahead of the probe
/// simply goes out with [profile] still null, which the header-injection
/// link treats as "send no header", the server's documented no-profile
/// behavior. A request after the probe resolves picks up [profile] with no
/// client rebuild, no orphaned in-flight query, and no subscription
/// reconnect.
class DeviceProfileHolder {
  DeviceProfileHolder();

  /// The one instance for the app's lifetime.
  ///
  /// `graphql_provider.dart`'s `deviceProfileHolderProvider` reads
  /// [instance] for the HTTP link; `P2pGraphQLLink` (`p2p_link.dart`) has no
  /// `ref` to read a provider through, so it reads [instance] directly. Both
  /// must see the one slot `detectDeviceProfile()` eventually writes into,
  /// not independent copies.
  ///
  /// Use the plain constructor, `DeviceProfileHolder()`, instead of
  /// [instance] only where an independent, non-shared holder is actually
  /// wanted, such as a test that scopes its own state rather than mutating
  /// the global.
  static final DeviceProfileHolder instance = DeviceProfileHolder();

  /// Null until the probe resolves, then fixed for the rest of the session.
  DeviceProfile? profile;
}
