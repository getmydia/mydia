/// Turns a browser's own codec answers into a [DeviceProfile].
///
/// The web profile used to be a fixed list asserting what "browsers" decode,
/// which was wrong in both directions at once. It claimed MP3 and VP8 that
/// Media Source Extensions will not accept, and it withheld HEVC and FLAC that
/// browsers have decoded for years — so every HEVC file was transcoded for a
/// client that could have stream-copied it.
///
/// The fixed list could not have been right, because there is no such thing as
/// what "browsers" decode. Measured on one Linux machine on the same day,
/// Firefox 154 accepts HEVC Main and Main 10 and refuses H.264 High 10;
/// Chromium 149 does the exact opposite. Only the browser in front of you can
/// answer, so this asks it.
///
/// ## Why MediaSource and not canPlayType
///
/// The web player always plays through an HLS session (`PlayerScreen` forces
/// it: `canDirect` is gated on `!kIsWeb`), and hls.js feeds Media Source
/// Extensions. `MediaSource.isTypeSupported` is therefore the oracle that
/// matches the pipeline the bytes actually travel; `canPlayType` answers for
/// `<video src=…>`, a path web never takes. They disagree often enough to
/// matter — Chromium 149 says `canPlayType('audio/mp4; codecs="mp4a.69"')` is
/// "probably" while `isTypeSupported` on the same string is false.
///
/// ## Why bit depth needs its own probe
///
/// A codec name cannot express "HEVC, but only 8-bit", and that is a real
/// browser: Firefox 154 takes H.264 High but not High 10. Claiming `h264` flat
/// would hand it a 10-bit file the server thought was approved. So every codec
/// with a depth axis is probed twice, and a codec that decodes 8-bit but not
/// 10-bit is claimed with a `VideoBitDepth <= 8` condition rather than
/// withheld — the same narrowing `android_codec_capabilities.dart` applies from
/// MediaCodec's tables, and the server already parses it
/// (`Mydia.Streaming.ProfileCondition`).
library;

// device_profile.dart re-exports CodecProfile, ProfileCondition and
// ProfileProperty, so it is the only import needed for both.
import 'device_profile.dart';

/// Answers whether the browser can decode `mimeType`.
///
/// Injected rather than imported so this logic is testable off-web: the real
/// implementation reaches through `dart:js_interop`, which the Dart VM the
/// tests run on cannot load.
typedef CodecProbe = bool Function(String mimeType);

/// One codec family: what to call it, and what to ask the browser about it.
class ProbedCodec {
  /// The names sent in the flat allowlists.
  ///
  /// Several per codec because the server substring-matches these against
  /// ffprobe *display* strings — `Mydia.Library.FileAnalyzer` writes
  /// "HEVC (Main 10)", "H.264 (High)", "DD+" — and the spelling that matches
  /// differs by source. Listing an alias that never matches anything is inert;
  /// omitting one that would have is a silent transcode.
  final List<String> aliases;

  /// MIME strings for the ordinary 8-bit form. Supported if *any* is.
  final List<String> probes;

  /// MIME strings for the >8-bit form, or empty for a codec with no depth
  /// axis (VP8 is 8-bit by specification, and no audio codec has one).
  ///
  /// When [probes] pass and these do not, the codec is claimed with a bit
  /// depth ceiling instead of being claimed outright.
  final List<String> highBitDepthProbes;

  const ProbedCodec({
    required this.aliases,
    required this.probes,
    this.highBitDepthProbes = const [],
  });
}

/// Video codecs worth asking about, most common first.
///
/// Codec strings are the concrete ones browsers actually answer for. A bare
/// family name like `hvc1` is not usable here: both browsers measured return
/// false for `video/mp4; codecs="hvc1"` while returning true for the same
/// codec fully qualified.
const List<ProbedCodec> kProbedVideoCodecs = [
  ProbedCodec(
    aliases: ['h264', 'h.264', 'avc', 'avc1'],
    probes: [
      'video/mp4; codecs="avc1.640028"',
      'video/mp4; codecs="avc1.42E01E"',
    ],
    // High 10 (profile_idc 110 = 0x6E). Firefox 154 refuses this and accepts
    // High, which is exactly the case a flat `h264` claim gets wrong.
    highBitDepthProbes: ['video/mp4; codecs="avc1.6E0028"'],
  ),
  ProbedCodec(
    aliases: ['hevc', 'h265', 'h.265', 'hvc1', 'hev1'],
    probes: [
      'video/mp4; codecs="hvc1.1.6.L93.B0"',
      'video/mp4; codecs="hev1.1.6.L93.B0"',
    ],
    highBitDepthProbes: [
      'video/mp4; codecs="hvc1.2.4.L120.B0"',
      'video/mp4; codecs="hev1.2.4.L120.B0"',
    ],
  ),
  ProbedCodec(
    aliases: ['av1', 'av01'],
    probes: ['video/mp4; codecs="av01.0.04M.08"'],
    highBitDepthProbes: ['video/mp4; codecs="av01.0.04M.10"'],
  ),
  ProbedCodec(
    aliases: ['vp9', 'vp09'],
    probes: [
      'video/mp4; codecs="vp09.00.10.08"',
      'video/webm; codecs="vp9"',
    ],
    highBitDepthProbes: ['video/mp4; codecs="vp09.02.10.10"'],
  ),
  ProbedCodec(
    aliases: ['vp8'],
    probes: ['video/webm; codecs="vp8"'],
  ),
];

/// Audio codecs worth asking about.
///
/// `dd+` is not a typo: `FileAnalyzer.extract_audio_codec/1` renders E-AC-3 as
/// "DD+", so that is the only spelling a substring match can find it under.
const List<ProbedCodec> kProbedAudioCodecs = [
  ProbedCodec(
    aliases: ['aac'],
    probes: [
      'audio/mp4; codecs="mp4a.40.2"',
      'audio/mp4; codecs="mp4a.40.5"',
    ],
  ),
  ProbedCodec(
    aliases: ['mp3'],
    probes: [
      'audio/mpeg',
      'audio/mp4; codecs="mp4a.69"',
      'audio/mp4; codecs="mp4a.6B"',
    ],
  ),
  ProbedCodec(
    aliases: ['opus'],
    probes: [
      'audio/mp4; codecs="opus"',
      'audio/webm; codecs="opus"',
    ],
  ),
  ProbedCodec(
    aliases: ['vorbis'],
    probes: ['audio/webm; codecs="vorbis"'],
  ),
  ProbedCodec(
    aliases: ['flac'],
    probes: [
      'audio/mp4; codecs="flac"',
      'audio/ogg; codecs="flac"',
    ],
  ),
  ProbedCodec(
    aliases: ['ac3', 'ac-3'],
    probes: ['audio/mp4; codecs="ac-3"'],
  ),
  ProbedCodec(
    aliases: ['dd+', 'eac3', 'ec-3'],
    probes: ['audio/mp4; codecs="ec-3"'],
  ),
  ProbedCodec(
    aliases: ['alac'],
    probes: ['audio/mp4; codecs="alac"'],
  ),
];

/// Builds the profile this browser should advertise.
///
/// Falls back to [DeviceProfile.webDefault] when the probe answers nothing for
/// video or nothing for audio. An empty allowlist is not a modest claim, it is
/// the maximal one — the server reads it as "transcode everything" — so a
/// browser whose `MediaSource` is missing or throwing lands on the fixed list
/// that shipped before this probe existed rather than on a profile that
/// guarantees a transcode. This mirrors `_probeMpvProfile`'s whole-profile
/// fallback in `device_profile_native.dart`.
DeviceProfile buildWebDeviceProfile(CodecProbe probe) {
  const fallback = DeviceProfile.webDefault();

  final videoCodecs = <String>[];
  final audioCodecs = <String>[];
  final codecProfiles = <CodecProfile>[];

  for (final codec in kProbedVideoCodecs) {
    if (!_anySupported(probe, codec.probes)) continue;

    videoCodecs.addAll(codec.aliases);

    final constrained = codec.highBitDepthProbes.isNotEmpty &&
        !_anySupported(probe, codec.highBitDepthProbes);
    if (!constrained) continue;

    // One profile per alias, not one per family. The server matches a codec
    // profile by the same substring rule as the allowlist, so an alias claimed
    // without a matching profile is an alias that slips past the ceiling.
    for (final alias in codec.aliases) {
      codecProfiles.add(
        CodecProfile.video(alias, const [
          ProfileCondition.atMost(ProfileProperty.videoBitDepth, '8'),
        ]),
      );
    }
  }

  for (final codec in kProbedAudioCodecs) {
    if (_anySupported(probe, codec.probes)) audioCodecs.addAll(codec.aliases);
  }

  if (videoCodecs.isEmpty || audioCodecs.isEmpty) return fallback;

  return DeviceProfile(
    // Not probed. These gate the server's DIRECT_PLAY branch, which asks what
    // a browser can *demux* from a plain URL — a different question from what
    // MediaSource accepts, and one no browser API answers. The fixed three are
    // still correct, and web reaches every one of them through an HLS session
    // anyway.
    containers: fallback.containers,
    videoCodecs: videoCodecs,
    audioCodecs: audioCodecs,
    // Left empty deliberately: the server parses hdrFormats but does not
    // enforce it (see Mydia.Streaming.DeviceProfile's moduledoc), and claiming
    // a tone-mapping capability no browser reports would be an invention.
    hdrFormats: const [],
    codecProfiles: codecProfiles,
  );
}

bool _anySupported(CodecProbe probe, List<String> mimeTypes) {
  for (final mimeType in mimeTypes) {
    if (probe(mimeType)) return true;
  }
  return false;
}
