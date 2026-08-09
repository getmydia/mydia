//! Port of lib/mydia/streaming/candidates.ex:93-147.
//!
//! Order is the whole point. The player reads the first entry and decides
//! whether it can play the file untouched (player_screen.dart:1344-1357), so
//! reordering this list changes playback behaviour even though every entry is
//! still present.

use crate::codec_string::{
    audio_codec_string, build_mime_type, video_codec_string, video_codec_variants,
};
use crate::compatibility::{check, container_format, Mode};

/// The transcode fallback is a fixed target, not derived from the source.
/// candidates.ex:113.
const TRANSCODE_VIDEO: &str = "avc1.640028";
const TRANSCODE_AUDIO: &str = "mp4a.40.2";
const TRANSCODE_CONTAINER: &str = "ts";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Strategy {
    DirectPlay,
    Remux,
    HlsCopy,
    Transcode,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Candidate {
    pub strategy: Strategy,
    pub mime: String,
    pub container: String,
    pub video_codec: Option<String>,
    pub audio_codec: Option<String>,
}

/// Everything the candidate list needs about a file. Taking facts rather than
/// a database row keeps this crate free of mydia-db.
#[derive(Debug, Clone)]
pub struct Facts {
    pub container: Option<String>,
    pub path: String,
    pub video_codec: Option<String>,
    pub audio_codec: Option<String>,
}

pub fn build(facts: &Facts) -> Vec<Candidate> {
    let container = container_format(facts.container.as_deref(), &facts.path);
    let video = video_codec_string(facts.video_codec.as_deref());
    let audio = audio_codec_string(facts.audio_codec.as_deref());

    let mode = check(
        Some(container.as_str()),
        facts.video_codec.as_deref(),
        facts.audio_codec.as_deref(),
    );

    match mode {
        Mode::DirectPlay => vec![
            candidate(
                Strategy::DirectPlay,
                &container,
                video.as_deref(),
                audio.as_deref(),
            ),
            transcode(),
        ],
        Mode::NeedsRemux => vec![
            // The remux produces fMP4, so the candidate advertises mp4.
            candidate(Strategy::Remux, "mp4", video.as_deref(), audio.as_deref()),
            candidate(
                Strategy::HlsCopy,
                TRANSCODE_CONTAINER,
                video.as_deref(),
                audio.as_deref(),
            ),
            transcode(),
        ],
        Mode::NeedsTranscoding => {
            let mut list: Vec<Candidate> = video_codec_variants(facts.video_codec.as_deref())
                .into_iter()
                .map(|variant| {
                    candidate(
                        Strategy::HlsCopy,
                        TRANSCODE_CONTAINER,
                        Some(variant.as_str()),
                        audio.as_deref(),
                    )
                })
                .collect();

            list.push(transcode());
            list
        }
    }
}

fn candidate(
    strategy: Strategy,
    container: &str,
    video: Option<&str>,
    audio: Option<&str>,
) -> Candidate {
    Candidate {
        strategy,
        mime: build_mime_type(container, video, audio),
        container: container.to_string(),
        video_codec: video.map(str::to_string),
        audio_codec: audio.map(str::to_string),
    }
}

fn transcode() -> Candidate {
    candidate(
        Strategy::Transcode,
        TRANSCODE_CONTAINER,
        Some(TRANSCODE_VIDEO),
        Some(TRANSCODE_AUDIO),
    )
}

#[cfg(test)]
mod tests {
    use super::{build, Facts, Strategy};

    fn facts(container: &str, video: &str, audio: Option<&str>) -> Facts {
        Facts {
            container: Some(container.to_string()),
            path: format!("/media/film.{container}"),
            video_codec: Some(video.to_string()),
            audio_codec: audio.map(str::to_string),
        }
    }

    #[test]
    fn a_direct_playable_file_offers_direct_play_then_transcode() {
        // candidates.ex:102-108.
        let list = build(&facts("mp4", "H.264 (High)", Some("AAC")));

        assert_eq!(list.len(), 2);
        assert_eq!(list[0].strategy, Strategy::DirectPlay);
        assert_eq!(list[0].container, "mp4");
        assert_eq!(list[0].video_codec.as_deref(), Some("avc1.640028"));
        assert_eq!(list[0].audio_codec.as_deref(), Some("mp4a.40.2"));
        assert_eq!(
            list[0].mime,
            r#"video/mp4; codecs="avc1.640028, mp4a.40.2""#
        );

        assert_eq!(list[1].strategy, Strategy::Transcode);
        assert_eq!(list[1].container, "ts");
        assert_eq!(list[1].video_codec.as_deref(), Some("avc1.640028"));
        assert_eq!(list[1].audio_codec.as_deref(), Some("mp4a.40.2"));
    }

    #[test]
    fn a_remuxable_file_offers_remux_then_hls_copy_then_transcode() {
        // candidates.ex:110-115. Note the remux candidate claims container
        // mp4, because that is what the remux produces.
        let list = build(&facts("mkv", "H.264 (High)", Some("AAC")));

        assert_eq!(
            list.iter().map(|c| c.strategy).collect::<Vec<_>>(),
            vec![Strategy::Remux, Strategy::HlsCopy, Strategy::Transcode]
        );
        assert_eq!(list[0].container, "mp4");
        assert_eq!(list[1].container, "ts");
    }

    #[test]
    fn a_transcoding_file_offers_one_hls_copy_per_codec_variant_then_transcode() {
        // candidates.ex:117-127. HEVC yields six variants, so seven entries.
        let list = build(&facts("mkv", "HEVC (Main 10)", Some("AAC")));

        assert_eq!(list.len(), 7);
        assert!(list[..6].iter().all(|c| c.strategy == Strategy::HlsCopy));
        assert_eq!(list[0].video_codec.as_deref(), Some("hvc1.2.4.L120.B0"));
        assert_eq!(list[6].strategy, Strategy::Transcode);
    }

    #[test]
    fn the_first_candidate_is_what_the_native_player_reads() {
        // player_screen.dart:1344-1357 direct-plays DIRECT_PLAY, REMUX and
        // HLS_COPY. This is the property that makes Slice 3a playable on its
        // own, so it gets its own test rather than living in a comment.
        for (container, video, audio) in [
            ("mp4", "H.264 (High)", Some("AAC")),
            ("mkv", "H.264 (High)", Some("AAC")),
            ("mkv", "HEVC (Main 10)", Some("DTS-HD MA")),
        ] {
            let first = build(&facts(container, video, audio))[0].strategy;
            assert!(
                matches!(
                    first,
                    Strategy::DirectPlay | Strategy::Remux | Strategy::HlsCopy
                ),
                "{container}/{video} led with {first:?}"
            );
        }
    }

    #[test]
    fn a_codec_with_no_variants_leads_with_transcode() {
        // The one case Slice 3a cannot play on its own, and the reason 3b
        // exists. MPEG-2 has no RFC 6381 string, so there are no HLS_COPY
        // candidates to put in front.
        let list = build(&facts("mkv", "MPEG-2", Some("AC3")));

        assert_eq!(list.len(), 1);
        assert_eq!(list[0].strategy, Strategy::Transcode);
    }

    #[test]
    fn the_transcode_candidate_is_always_the_same_constant() {
        // candidates.ex:113,122,126 all use the same triple.
        for f in [
            facts("mp4", "H.264 (High)", Some("AAC")),
            facts("mkv", "H.264 (High)", Some("AAC")),
            facts("mkv", "HEVC (Main)", Some("DTS")),
        ] {
            let list = build(&f);
            let last = list.last().unwrap();
            assert_eq!(last.strategy, Strategy::Transcode);
            assert_eq!(last.container, "ts");
            assert_eq!(last.video_codec.as_deref(), Some("avc1.640028"));
            assert_eq!(last.audio_codec.as_deref(), Some("mp4a.40.2"));
            assert_eq!(last.mime, r#"video/mp2t; codecs="avc1.640028, mp4a.40.2""#);
        }
    }

    #[test]
    fn a_file_with_no_recorded_container_uses_its_extension() {
        let list = build(&Facts {
            container: None,
            path: "/media/Some Film (2019).mkv".to_string(),
            video_codec: Some("H.264 (High)".to_string()),
            audio_codec: Some("AAC".to_string()),
        });

        assert_eq!(list[0].strategy, Strategy::Remux);
    }
}
