/// Per-codec constraints a client attaches to a codec it claims to decode.
///
/// A codec name alone cannot answer "can this device play this file". The
/// tablet that motivated these decodes HEVC Main and refuses HEVC Main 10, and
/// libmpv's `decoder-list` — the native profile's source — reports what
/// libavcodec was *compiled* with, so it says "hevc" for both.
///
/// The vocabulary mirrors Jellyfin's `ProfileCondition` and Plex's device
/// profiles rather than inventing a Mydia dialect. The server parses the same
/// names in `Mydia.Streaming.ProfileCondition`.
library;

/// The properties the server knows how to resolve from a stream.
///
/// Kept as constants rather than free strings so a typo is a compile error here
/// instead of a constraint the server rejects at runtime — a rejected payload
/// is treated as *absent*, which silently widens direct play rather than
/// narrowing it.
abstract final class ProfileProperty {
  static const videoBitDepth = 'VideoBitDepth';
  static const videoProfile = 'VideoProfile';
  static const videoLevel = 'VideoLevel';
  static const width = 'Width';
  static const height = 'Height';
  static const videoFramerate = 'VideoFramerate';
  static const audioChannels = 'AudioChannels';
  static const audioSampleRate = 'AudioSampleRate';
  static const audioProfile = 'AudioProfile';
}

/// The comparisons the server implements.
abstract final class ProfileComparison {
  static const equals = 'Equals';
  static const notEquals = 'NotEquals';
  static const lessThanEqual = 'LessThanEqual';
  static const greaterThanEqual = 'GreaterThanEqual';

  /// Value is a `|`-separated list, e.g. `'Main|Main 10'`.
  static const equalsAny = 'EqualsAny';
}

/// One constraint on one codec.
class ProfileCondition {
  final String property;
  final String condition;
  final String value;

  /// When true (the default), a stream whose value for [property] is unknown
  /// fails this condition. That is the safe direction: the alternative hands
  /// the client a stream it never approved.
  final bool isRequired;

  const ProfileCondition({
    required this.property,
    required this.condition,
    required this.value,
    this.isRequired = true,
  });

  /// `property <= value`, the common shape for a ceiling.
  const ProfileCondition.atMost(this.property, this.value,
      {this.isRequired = true})
      : condition = ProfileComparison.lessThanEqual;

  Map<String, dynamic> toJson() => {
        'property': property,
        'condition': condition,
        'value': value,
        'isRequired': isRequired,
      };

  @override
  String toString() => 'ProfileCondition($property $condition $value)';
}

/// The constraints attached to one codec.
///
/// Conditions are ANDed. An empty list claims the codec unconditionally.
class CodecProfile {
  /// `'video'` or `'audio'`.
  final String type;

  /// The codec name, matched as a substring by the server so `'hevc'` also
  /// covers the display strings ffprobe produces.
  final String codec;

  final List<ProfileCondition> conditions;

  const CodecProfile({
    required this.type,
    required this.codec,
    this.conditions = const [],
  });

  const CodecProfile.video(this.codec, this.conditions) : type = 'video';

  const CodecProfile.audio(this.codec, this.conditions) : type = 'audio';

  Map<String, dynamic> toJson() => {
        'type': type,
        'codec': codec,
        'conditions': conditions.map((c) => c.toJson()).toList(),
      };

  @override
  String toString() =>
      'CodecProfile($type/$codec, ${conditions.length} condition(s))';
}
