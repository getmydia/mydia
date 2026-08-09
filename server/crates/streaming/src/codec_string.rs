//! Port of lib/mydia/streaming/codec_string.ex.
//!
//! The Elixir module prefers raw ffprobe profile and level integers when the
//! metadata carries them, and derives from the human-readable profile name
//! otherwise. Nothing in the Elixir codebase ever writes those integers:
//! `video_profile_idc` and friends appear only on the FileMetadata struct and
//! in codec_string.ex itself. The Elixir server therefore always takes the
//! derived branch, and so does this port. Adding the raw branch here would
//! make Mydia Server answer differently from the server it is measured
//! against.

/// Level 4.0 covers 1080p at 30fps. codec_string.ex:194.
const H264_DEFAULT_LEVEL: u32 = 40;
/// Level 4.0 for HEVC is level_idc 120. codec_string.ex:290.
const HEVC_DEFAULT_LEVEL: u32 = 120;

/// codec_string.ex:56-67.
pub fn video_codec_string(codec: Option<&str>) -> Option<String> {
    let codec = codec?;
    let c = codec.to_lowercase();

    if is_h264(&c) {
        let (profile, constraint) = h264_profile(&c);
        Some(format_avc1(profile, constraint, H264_DEFAULT_LEVEL))
    } else if is_hevc(&c) {
        let (profile, tier) = hevc_profile(&c);
        Some(format_hvc1("hvc1", profile, tier, HEVC_DEFAULT_LEVEL))
    } else if c.contains("vp9") {
        Some("vp09.00.31.08".to_string())
    } else if c.contains("vp8") {
        Some("vp8".to_string())
    } else if c.contains("av1") {
        Some("av01.0.09M.08".to_string())
    } else {
        None
    }
}

/// codec_string.ex:84-100. DTS, TrueHD and PCM have no RFC 6381 string, which
/// is why they answer None rather than a guess.
pub fn audio_codec_string(codec: Option<&str>) -> Option<String> {
    let codec = codec?;
    let c = codec.to_lowercase();

    if c.contains("aac") {
        // codec_string.ex:409-424. The HE-AAC v2 arm in the Elixir source is
        // unreachable, because the plain HE-AAC arm above it matches first.
        // Reproduced as written rather than as intended.
        if c.contains("he-aac") || c.contains("aac-he") {
            Some("mp4a.40.5".to_string())
        } else {
            Some("mp4a.40.2".to_string())
        }
    } else if c.contains("mp3") {
        Some("mp4a.40.34".to_string())
    } else if c.contains("ac3") && !c.contains("eac3") {
        Some("ac-3".to_string())
    } else if c.contains("eac3") || c.contains("dd+") {
        Some("ec-3".to_string())
    } else if c.contains("opus") {
        Some("opus".to_string())
    } else if c.contains("vorbis") {
        Some("vorbis".to_string())
    } else if c.contains("flac") {
        Some("flac".to_string())
    } else {
        None
    }
}

/// codec_string.ex:144-155. Ordered most specific to most generic.
pub fn video_codec_variants(codec: Option<&str>) -> Vec<String> {
    let Some(codec) = codec else {
        return Vec::new();
    };
    let c = codec.to_lowercase();

    let variants: Vec<String> = if is_h264(&c) {
        let primary = video_codec_string(Some(codec)).unwrap_or_default();
        vec![
            primary,
            "avc1.640028".to_string(),
            "avc1.4d4028".to_string(),
            "avc1".to_string(),
        ]
    } else if is_hevc(&c) {
        let (profile, tier) = hevc_profile(&c);
        vec![
            format_hvc1("hvc1", profile, tier, HEVC_DEFAULT_LEVEL),
            format_hvc1("hev1", profile, tier, HEVC_DEFAULT_LEVEL),
            "hvc1.1.6.L93.B0".to_string(),
            "hev1.1.6.L93.B0".to_string(),
            "hvc1".to_string(),
            "hev1".to_string(),
        ]
    } else if c.contains("vp9") {
        vec!["vp09.00.31.08".to_string(), "vp9".to_string()]
    } else if c.contains("vp8") {
        vec!["vp8".to_string()]
    } else if c.contains("av1") {
        vec![
            "av01.0.09M.08".to_string(),
            "av01.0.08M.08".to_string(),
            "av01.0.00M.08".to_string(),
            "av01".to_string(),
        ]
    } else {
        Vec::new()
    };

    dedup_preserving_order(variants)
}

/// codec_string.ex:116-129.
pub fn build_mime_type(container: &str, video: Option<&str>, audio: Option<&str>) -> String {
    let base = container_to_mime(container);

    let codecs: Vec<&str> = [video, audio].into_iter().flatten().collect();

    if codecs.is_empty() {
        base.to_string()
    } else {
        format!(r#"{base}; codecs="{}""#, codecs.join(", "))
    }
}

fn is_h264(c: &str) -> bool {
    c.contains("h264") || c.contains("h.264") || c.contains("avc")
}

fn is_hevc(c: &str) -> bool {
    c.contains("hevc") || c.contains("h265") || c.contains("h.265")
}

/// codec_string.ex:196-232, returning (profile_idc, constraint_flags).
fn h264_profile(c: &str) -> (u32, u32) {
    if c.contains("constrained baseline") {
        (66, 0x40)
    } else if c.contains("baseline") {
        (66, 0x00)
    } else if c.contains("main") {
        (77, 0x00)
    } else if c.contains("high 10") || c.contains("high10") {
        (110, 0x00)
    } else if c.contains("high 4:2:2") || c.contains("high422") {
        (122, 0x00)
    } else if c.contains("high 4:4:4") || c.contains("high444") {
        (244, 0x00)
    } else {
        // Covers both "High" and generic H.264. codec_string.ex:225-230.
        (100, 0x00)
    }
}

/// codec_string.ex:292-316, returning (profile_idc, tier_flag).
fn hevc_profile(c: &str) -> (u32, u32) {
    if c.contains("main 10") || c.contains("main10") {
        (2, 0)
    } else if c.contains("still") {
        (3, 0)
    } else if c.contains("main") {
        (1, 0)
    } else if c.contains("rext") {
        (2, 0)
    } else {
        (1, 0)
    }
}

fn format_avc1(profile: u32, constraint: u32, level: u32) -> String {
    format!("avc1.{:02x}{:02x}{:02x}", profile, constraint, level)
}

/// codec_string.ex:276-286. The compatibility field is 4 for every profile the
/// Elixir module knows about, including its catch-all.
fn format_hvc1(prefix: &str, profile: u32, tier: u32, level: u32) -> String {
    let tier_char = if tier == 1 { 'H' } else { 'L' };
    format!("{prefix}.{profile}.4.{tier_char}{level}.B0")
}

/// codec_string.ex:462-469.
fn container_to_mime(container: &str) -> &'static str {
    match container {
        "mp4" | "m4v" | "mov" => "video/mp4",
        "mkv" => "video/x-matroska",
        "webm" => "video/webm",
        "ts" => "video/mp2t",
        "avi" => "video/x-msvideo",
        _ => "video/mp4",
    }
}

/// Elixir's Enum.uniq keeps the first occurrence. HashSet-based dedup would
/// not preserve order, and the order is the point of a variant list.
fn dedup_preserving_order(items: Vec<String>) -> Vec<String> {
    let mut seen = Vec::new();
    for item in items {
        if !seen.contains(&item) {
            seen.push(item);
        }
    }
    seen
}

#[cfg(test)]
mod tests {
    use super::{audio_codec_string, build_mime_type, video_codec_string, video_codec_variants};

    #[test]
    fn h264_profiles_map_to_their_profile_idc() {
        // avc1.PPCCLL, all hex. Level is always 40 (0x28) because nothing
        // populates the raw level field.
        assert_eq!(
            video_codec_string(Some("H.264 (High)")).as_deref(),
            Some("avc1.640028")
        );
        assert_eq!(
            video_codec_string(Some("H.264 (Main)")).as_deref(),
            Some("avc1.4d0028")
        );
        assert_eq!(
            video_codec_string(Some("H.264 (Baseline)")).as_deref(),
            Some("avc1.420028")
        );
        assert_eq!(
            video_codec_string(Some("H.264 (Constrained Baseline)")).as_deref(),
            Some("avc1.424028")
        );
        assert_eq!(
            video_codec_string(Some("H.264 (High 10)")).as_deref(),
            Some("avc1.6e0028")
        );
        assert_eq!(
            video_codec_string(Some("H.264")).as_deref(),
            Some("avc1.640028")
        );
    }

    #[test]
    fn constrained_baseline_wins_over_baseline() {
        // codec_string.ex:201-206 checks the longer phrase first. A plain
        // substring order here would answer avc1.420028 for both.
        assert_ne!(
            video_codec_string(Some("H.264 (Constrained Baseline)")),
            video_codec_string(Some("H.264 (Baseline)"))
        );
    }

    #[test]
    fn hevc_profiles_map_to_hvc1_strings() {
        assert_eq!(
            video_codec_string(Some("HEVC (Main)")).as_deref(),
            Some("hvc1.1.4.L120.B0")
        );
        assert_eq!(
            video_codec_string(Some("HEVC (Main 10)")).as_deref(),
            Some("hvc1.2.4.L120.B0")
        );
        assert_eq!(
            video_codec_string(Some("HEVC")).as_deref(),
            Some("hvc1.1.4.L120.B0")
        );
    }

    #[test]
    fn the_simple_codecs_answer_constants() {
        assert_eq!(
            video_codec_string(Some("VP9")).as_deref(),
            Some("vp09.00.31.08")
        );
        assert_eq!(video_codec_string(Some("VP8")).as_deref(), Some("vp8"));
        assert_eq!(
            video_codec_string(Some("AV1")).as_deref(),
            Some("av01.0.09M.08")
        );
    }

    #[test]
    fn an_unrecognised_video_codec_has_no_codec_string() {
        assert_eq!(video_codec_string(Some("MPEG-2")), None);
        assert_eq!(video_codec_string(None), None);
    }

    #[test]
    fn audio_codecs_map_to_their_rfc_strings() {
        assert_eq!(
            audio_codec_string(Some("AAC")).as_deref(),
            Some("mp4a.40.2")
        );
        assert_eq!(
            audio_codec_string(Some("AAC 5.1")).as_deref(),
            Some("mp4a.40.2")
        );
        assert_eq!(
            audio_codec_string(Some("HE-AAC")).as_deref(),
            Some("mp4a.40.5")
        );
        assert_eq!(
            audio_codec_string(Some("MP3")).as_deref(),
            Some("mp4a.40.34")
        );
        assert_eq!(audio_codec_string(Some("AC3")).as_deref(), Some("ac-3"));
        assert_eq!(audio_codec_string(Some("Opus")).as_deref(), Some("opus"));
        assert_eq!(audio_codec_string(Some("FLAC")).as_deref(), Some("flac"));
    }

    #[test]
    fn lossless_and_unknown_audio_has_no_codec_string() {
        // codec_string.ex:92-97 answers nil for DTS, TrueHD and PCM.
        assert_eq!(audio_codec_string(Some("DTS-HD MA")), None);
        assert_eq!(audio_codec_string(Some("TrueHD Atmos")), None);
        assert_eq!(audio_codec_string(Some("PCM")), None);
        assert_eq!(audio_codec_string(None), None);
    }

    #[test]
    fn dd_plus_is_eac3_and_plain_ac3_is_not() {
        // codec_string.ex:449-450. ffprobe's label for eac3 is "DD+"
        // (ffprobe.rs:270), which the ac3 branch must not swallow.
        assert_eq!(audio_codec_string(Some("DD+")).as_deref(), Some("ec-3"));
        assert_eq!(audio_codec_string(Some("EAC3")).as_deref(), Some("ec-3"));
        assert_eq!(audio_codec_string(Some("AC3")).as_deref(), Some("ac-3"));
    }

    #[test]
    fn mime_types_carry_the_codecs_parameter() {
        assert_eq!(
            build_mime_type("mp4", Some("avc1.640028"), Some("mp4a.40.2")),
            r#"video/mp4; codecs="avc1.640028, mp4a.40.2""#
        );
        // A nil audio string drops out rather than leaving a trailing comma.
        assert_eq!(
            build_mime_type("mkv", Some("avc1.640028"), None),
            r#"video/x-matroska; codecs="avc1.640028""#
        );
        // Both absent leaves a bare type.
        assert_eq!(build_mime_type("ts", None, None), "video/mp2t");
        // Unknown containers answer video/mp4 (codec_string.ex:469).
        assert_eq!(build_mime_type("ogv", None, None), "video/mp4");
    }

    #[test]
    fn variants_run_specific_to_generic_without_duplicates() {
        // codec_string.ex:234-245. The High primary equals the first fallback,
        // so Enum.uniq collapses them.
        assert_eq!(
            video_codec_variants(Some("H.264 (High)")),
            vec!["avc1.640028", "avc1.4d4028", "avc1"]
        );
        assert_eq!(
            video_codec_variants(Some("H.264 (Main)")),
            vec!["avc1.4d0028", "avc1.640028", "avc1.4d4028", "avc1"]
        );
        assert_eq!(
            video_codec_variants(Some("HEVC (Main)")),
            vec![
                "hvc1.1.4.L120.B0",
                "hev1.1.4.L120.B0",
                "hvc1.1.6.L93.B0",
                "hev1.1.6.L93.B0",
                "hvc1",
                "hev1"
            ]
        );
        assert_eq!(video_codec_variants(Some("MPEG-2")), Vec::<String>::new());
    }
}
