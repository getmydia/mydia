//! Vocabulary tables — token forms that the classifier matches with
//! high confidence.
//!
//! Phoenix uses `MapSet`s of normalized tokens for these lookups. We
//! match the shape with `&[&str]` constants checked at compile time;
//! the lowercase-once-then-`.contains` lookup is fast enough at the
//! sizes here. A canonical-form returner accompanies each table for
//! the cases where downstream code wants the casing the vocab
//! intends (`"BluRay"` not `"bluray"`).
//!
//! Sourced from `lib/mydia/library/release_parser/vocabulary.ex` and
//! `vocabulary_entry.ex`.

/// Known scene release sources.
pub const SOURCES: &[&str] = &[
    "bluray", "bdrip", "brrip", "webdl", "web-dl", "webrip", "web", "hdtv", "dvd", "dvdrip",
    "dvdscr", "remux", "uhd", "bdr",
];

/// Canonical casing for known sources, for [`canonical_source`].
const SOURCE_CANONICAL: &[(&str, &str)] = &[
    ("bluray", "BluRay"),
    ("bdrip", "BDRip"),
    ("brrip", "BRRip"),
    ("webdl", "WEB-DL"),
    ("web-dl", "WEB-DL"),
    ("webrip", "WEBRip"),
    ("web", "WEB"),
    ("hdtv", "HDTV"),
    ("dvd", "DVD"),
    ("dvdrip", "DVDRip"),
    ("dvdscr", "DVDScr"),
    ("remux", "REMUX"),
    ("uhd", "UHD"),
    ("bdr", "BDR"),
];

/// Known video codecs (raw token forms — see [`canonical_codec`]).
pub const CODECS: &[&str] = &[
    "x264", "x265", "h264", "h265", "h.264", "h.265", "hevc", "avc", "xvid", "divx", "vp9", "av1",
    "nvenc",
];

const CODEC_CANONICAL: &[(&str, &str)] = &[
    ("x264", "x264"),
    ("x265", "x265"),
    ("h264", "H.264"),
    ("h265", "H.265"),
    ("h.264", "H.264"),
    ("h.265", "H.265"),
    ("hevc", "HEVC"),
    ("avc", "AVC"),
    ("xvid", "XviD"),
    ("divx", "DivX"),
    ("vp9", "VP9"),
    ("av1", "AV1"),
    ("nvenc", "NVENC"),
];

/// HDR markers.
pub const HDR_MARKERS: &[&str] = &[
    "hdr",
    "hdr10",
    "hdr10+",
    "dolbyvision",
    "dolby vision",
    "dovi",
    "dv",
];

const HDR_CANONICAL: &[(&str, &str)] = &[
    ("hdr", "HDR"),
    ("hdr10", "HDR10"),
    ("hdr10+", "HDR10+"),
    ("dolbyvision", "Dolby Vision"),
    ("dovi", "Dolby Vision"),
    ("dv", "DV"),
];

/// Streaming-service tags that scene releases include before the
/// source token (e.g. `AMZN.WEB-DL`).
pub const STREAMING_SERVICES: &[&str] = &[
    "amzn", "nf", "atvp", "dsnp", "hmax", "hulu", "pmtp", "pcok", "stan", "max",
];

/// Languages (small subset — used to filter title tokens).
pub const LANGUAGES: &[&str] = &[
    "english",
    "french",
    "spanish",
    "german",
    "italian",
    "japanese",
    "korean",
    "chinese",
    "russian",
    "dutch",
    "swedish",
    "danish",
    "norwegian",
    "finnish",
    "polish",
    "portuguese",
    "turkish",
    "hebrew",
    "arabic",
    "hindi",
];

/// Edition markers — collapsed into the title or dropped depending
/// on context. The classifier returns these as a low-priority hint.
pub const EDITIONS: &[&str] = &[
    "proper",
    "repack",
    "internal",
    "limited",
    "unrated",
    "extended",
    "theatrical",
    "hybrid",
    "directors",
    "criterion",
];

/// Audio-codec roots — the suffix (`5.1`, `7.1`, ...) is matched
/// separately.
pub const AUDIO_ROOTS: &[&str] = &[
    "aac", "ac3", "dd", "ddp", "eac3", "atmos", "dts", "truehd", "flac", "opus", "mp3",
];

const AUDIO_CANONICAL: &[(&str, &str)] = &[
    ("aac", "AAC"),
    ("ac3", "AC3"),
    ("dd", "DD"),
    ("ddp", "DDP"),
    ("eac3", "EAC3"),
    ("atmos", "Atmos"),
    ("dts", "DTS"),
    ("truehd", "TrueHD"),
    ("flac", "FLAC"),
    ("opus", "Opus"),
    ("mp3", "MP3"),
];

#[must_use]
pub fn is_source(value: &str) -> bool {
    SOURCES.contains(&value.to_lowercase().as_str())
}

#[must_use]
pub fn is_codec(value: &str) -> bool {
    CODECS.contains(&value.to_lowercase().as_str())
}

#[must_use]
pub fn is_hdr(value: &str) -> bool {
    HDR_MARKERS.contains(&value.to_lowercase().as_str())
}

#[must_use]
pub fn is_streaming_service(value: &str) -> bool {
    STREAMING_SERVICES.contains(&value.to_lowercase().as_str())
}

#[must_use]
pub fn is_language(value: &str) -> bool {
    LANGUAGES.contains(&value.to_lowercase().as_str())
}

#[must_use]
pub fn is_edition(value: &str) -> bool {
    EDITIONS.contains(&value.to_lowercase().as_str())
}

#[must_use]
pub fn is_audio_root(value: &str) -> bool {
    AUDIO_ROOTS.contains(&value.to_lowercase().as_str())
}

/// Resolve canonical casing for a token recognized via [`is_source`].
#[must_use]
pub fn canonical_source(value: &str) -> Option<&'static str> {
    let lower = value.to_lowercase();
    SOURCE_CANONICAL
        .iter()
        .find_map(|(k, v)| (lower == *k).then_some(*v))
}

#[must_use]
pub fn canonical_codec(value: &str) -> Option<&'static str> {
    let lower = value.to_lowercase();
    CODEC_CANONICAL
        .iter()
        .find_map(|(k, v)| (lower == *k).then_some(*v))
}

#[must_use]
pub fn canonical_hdr(value: &str) -> Option<&'static str> {
    let lower = value.to_lowercase();
    HDR_CANONICAL
        .iter()
        .find_map(|(k, v)| (lower == *k).then_some(*v))
}

#[must_use]
pub fn canonical_audio(value: &str) -> Option<&'static str> {
    let lower = value.to_lowercase();
    AUDIO_CANONICAL
        .iter()
        .find_map(|(k, v)| (lower == *k).then_some(*v))
}
