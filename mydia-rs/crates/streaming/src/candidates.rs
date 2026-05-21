//! Streaming candidate selection. Port of
//! `lib/mydia/streaming/candidates.ex` (`build_streaming_candidates/1`).
//!
//! Given a [`MediaFile`], produces a ranked list of strategies the
//! player should try in order. The GraphQL `playback.candidates`
//! resolver in U11 reads this list; the supervisor in this crate picks
//! the head when actually spawning a session via
//! [`resolve_strategy`].

use mydia_rs_models::MediaFile;
use serde::{Deserialize, Serialize};

use crate::codec::{
    media_file_container, normalize_audio_codec, normalize_video_codec, streaming_mode_for,
    StreamingMode,
};

/// Discrete strategies the player understands. Wire-compatible with
/// the `strategy` field Phoenix returns (`DIRECT_PLAY`, `REMUX`,
/// `HLS_COPY`, `TRANSCODE`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum StreamingStrategy {
    DirectPlay,
    Remux,
    HlsCopy,
    Transcode,
}

impl StreamingStrategy {
    /// Phoenix wire string for this strategy. Kept in one place so the
    /// parity-replay harness (U13) and GraphQL serializers (U11) can't
    /// drift.
    #[must_use]
    pub fn as_phoenix_str(&self) -> &'static str {
        match self {
            Self::DirectPlay => "DIRECT_PLAY",
            Self::Remux => "REMUX",
            Self::HlsCopy => "HLS_COPY",
            Self::Transcode => "TRANSCODE",
        }
    }
}

/// One candidate row. Surfaced to the GraphQL `PlaybackCandidate`
/// object in U11.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StreamingCandidate {
    pub strategy: StreamingStrategy,
    pub container: String,
    pub video_codec: String,
    pub audio_codec: String,
    pub mime: String,
}

/// MIME used when no original codec info is available; matches the
/// safe-fallback transcode candidate Phoenix emits
/// (`"avc1.640028", "mp4a.40.2"`).
const TRANSCODE_VIDEO_CODEC: &str = "avc1.640028";
const TRANSCODE_AUDIO_CODEC: &str = "mp4a.40.2";

/// Build the prioritized candidate list a player should walk through.
/// The first entry is the preferred strategy; subsequent entries are
/// fallbacks for clients that reject the leading candidate.
#[must_use]
pub fn build_streaming_candidates(media_file: &MediaFile) -> Vec<StreamingCandidate> {
    let mode = streaming_mode_for(media_file);
    let video_codec = normalize_video_codec(media_file.codec.as_deref())
        .unwrap_or_else(|| TRANSCODE_VIDEO_CODEC.to_string());
    let audio_codec = normalize_audio_codec(media_file.audio_codec.as_deref())
        .unwrap_or_else(|| TRANSCODE_AUDIO_CODEC.to_string());

    match mode {
        StreamingMode::DirectPlay => {
            let container = media_file_container(media_file).unwrap_or_else(|| "mp4".to_string());
            vec![
                build_candidate(
                    StreamingStrategy::DirectPlay,
                    &container,
                    &video_codec,
                    &audio_codec,
                ),
                build_candidate(
                    StreamingStrategy::Transcode,
                    "ts",
                    TRANSCODE_VIDEO_CODEC,
                    TRANSCODE_AUDIO_CODEC,
                ),
            ]
        }
        StreamingMode::NeedsRemux => vec![
            build_candidate(StreamingStrategy::Remux, "mp4", &video_codec, &audio_codec),
            build_candidate(StreamingStrategy::HlsCopy, "ts", &video_codec, &audio_codec),
            build_candidate(
                StreamingStrategy::Transcode,
                "ts",
                TRANSCODE_VIDEO_CODEC,
                TRANSCODE_AUDIO_CODEC,
            ),
        ],
        StreamingMode::NeedsTranscoding => vec![
            build_candidate(StreamingStrategy::HlsCopy, "ts", &video_codec, &audio_codec),
            build_candidate(
                StreamingStrategy::Transcode,
                "ts",
                TRANSCODE_VIDEO_CODEC,
                TRANSCODE_AUDIO_CODEC,
            ),
        ],
    }
}

/// Convenience: the strategy the supervisor would pick today (head of
/// the candidate list). Used internally; resolvers should prefer
/// [`build_streaming_candidates`] so they can surface the full list to
/// the player.
#[must_use]
pub fn resolve_strategy(media_file: &MediaFile) -> StreamingStrategy {
    build_streaming_candidates(media_file)
        .first()
        .map_or(StreamingStrategy::Transcode, |c| c.strategy)
}

fn build_candidate(
    strategy: StreamingStrategy,
    container: &str,
    video_codec: &str,
    audio_codec: &str,
) -> StreamingCandidate {
    StreamingCandidate {
        strategy,
        container: container.to_string(),
        video_codec: video_codec.to_string(),
        audio_codec: audio_codec.to_string(),
        mime: build_mime(container, video_codec, audio_codec),
    }
}

fn build_mime(container: &str, video_codec: &str, audio_codec: &str) -> String {
    let mime_type = match container.to_ascii_lowercase().as_str() {
        "webm" => "video/webm",
        "mkv" | "matroska" => "video/x-matroska",
        "ts" | "mpegts" => "video/mp2t",
        // mp4, m4v, and unknowns all fall through to video/mp4.
        _ => "video/mp4",
    };
    format!("{mime_type}; codecs=\"{video_codec},{audio_codec}\"")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::media_file_fixture;

    #[test]
    fn direct_play_for_browser_compatible_mp4() {
        let mut media = media_file_fixture();
        media.codec = Some("h264".into());
        media.audio_codec = Some("aac".into());
        media.path = Some("/foo/bar.mp4".into());

        let candidates = build_streaming_candidates(&media);
        assert_eq!(candidates[0].strategy, StreamingStrategy::DirectPlay);
        assert_eq!(candidates[0].container, "mp4");
        assert_eq!(resolve_strategy(&media), StreamingStrategy::DirectPlay);
    }

    #[test]
    fn remux_for_mkv_with_browser_codecs() {
        let mut media = media_file_fixture();
        media.codec = Some("h264".into());
        media.audio_codec = Some("aac".into());
        media.path = Some("/foo/bar.mkv".into());

        let candidates = build_streaming_candidates(&media);
        assert_eq!(candidates[0].strategy, StreamingStrategy::Remux);
        assert_eq!(candidates[0].container, "mp4");
        assert_eq!(candidates[1].strategy, StreamingStrategy::HlsCopy);
    }

    #[test]
    fn transcode_for_hevc() {
        let mut media = media_file_fixture();
        media.codec = Some("hevc".into());
        media.audio_codec = Some("aac".into());
        media.path = Some("/foo/bar.mkv".into());

        let candidates = build_streaming_candidates(&media);
        assert_eq!(candidates[0].strategy, StreamingStrategy::HlsCopy);
        assert_eq!(
            candidates.last().unwrap().strategy,
            StreamingStrategy::Transcode
        );
    }

    #[test]
    fn phoenix_strategy_strings_are_stable() {
        // The strings are part of the wire contract during the parallel
        // cutover window — Phoenix and mydia-rs must emit the same set.
        assert_eq!(
            StreamingStrategy::DirectPlay.as_phoenix_str(),
            "DIRECT_PLAY"
        );
        assert_eq!(StreamingStrategy::Remux.as_phoenix_str(), "REMUX");
        assert_eq!(StreamingStrategy::HlsCopy.as_phoenix_str(), "HLS_COPY");
        assert_eq!(StreamingStrategy::Transcode.as_phoenix_str(), "TRANSCODE");
    }
}
