//! The player-to-player control protocol.
//!
//! Deliberately free of iroh and of any I/O, so it unit-tests in isolation and
//! compiles for wasm unchanged. The transport is `MydiaRequest::RemoteControl`.

/// The protocol revision this build speaks. Bump when a command's meaning
/// changes, never when one is merely added: `TargetCapabilities` is how a
/// target declines a command it does not implement.
pub const PROTOCOL_VERSION: u32 = 1;

#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub enum RemoteControlRequest {
    Hello {
        controller_name: String,
        protocol_version: u32,
    },
    GetState,
    Play,
    Pause,
    Stop,
    Seek {
        position_ms: u64,
    },
    SetVolume {
        /// 0.0 to 1.0. Out of range values are clamped by the target.
        level: f32,
    },
    SetMute {
        muted: bool,
    },
    SelectAudioTrack {
        /// `None` means "no track", which is meaningful for subtitles and is
        /// accepted here for symmetry rather than special-cased.
        id: Option<String>,
    },
    SelectSubtitleTrack {
        id: Option<String>,
    },
    NextEpisode,
    PreviousEpisode,
    LoadContent(LoadContentRequest),
}

/// What to play, as a reference the target resolves against the server it is
/// already paired to.
///
/// Never a URL. A Chromecast has to be handed a URL it can reach, which is why
/// `CastFailureKind::unreachable` exists; a Mydia target has its own session
/// with the server and that whole failure mode does not apply.
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct LoadContentRequest {
    pub media_item_id: String,
    pub episode_id: Option<String>,
    pub position_ms: u64,
    pub audio_track: Option<String>,
    pub subtitle_track: Option<String>,
    pub autoplay: bool,
}

#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub enum RemoteControlResponse {
    /// Answer to `Hello`. Carries what this target can actually do.
    Welcome {
        target_name: String,
        protocol_version: u32,
        capabilities: TargetCapabilities,
    },
    State(PlaybackSnapshot),
    /// The command was applied. The controller re-reads state immediately
    /// rather than trusting this to describe the result.
    Accepted,
    /// The peer is not in this target's roster.
    NotAuthorized,
    /// No player is mounted, so there is nothing to command.
    NotPlaying,
    /// The target understood the command and does not implement it.
    Unsupported,
    Error(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub enum PlaybackState {
    Idle,
    Loading,
    Buffering,
    Playing,
    Paused,
    Ended,
    Error,
}

#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct TrackInfo {
    pub id: String,
    pub label: String,
    pub language: Option<String>,
}

/// What a target implements. The controller hides what is not offered rather
/// than sending commands that quietly do nothing.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct TargetCapabilities {
    pub volume: bool,
    pub track_selection: bool,
    pub next_previous: bool,
}

#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct PlaybackSnapshot {
    pub state: PlaybackState,
    pub media_item_id: Option<String>,
    pub episode_id: Option<String>,
    pub title: String,
    pub subtitle: Option<String>,
    pub image_url: Option<String>,
    pub position_ms: u64,
    pub duration_ms: u64,
    pub volume: Option<f32>,
    pub muted: bool,
    pub audio_tracks: Vec<TrackInfo>,
    pub subtitle_tracks: Vec<TrackInfo>,
    pub selected_audio: Option<String>,
    pub selected_subtitle: Option<String>,
    pub capabilities: TargetCapabilities,
    /// Monotonic per target. Two controllers polling the same target use this
    /// to discard a snapshot that raced behind one they already rendered.
    pub sequence: u64,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_seek_command_round_trips() {
        let request = RemoteControlRequest::Seek {
            position_ms: 754_000,
        };
        let bytes = serde_cbor::to_vec(&request).unwrap();
        let decoded: RemoteControlRequest = serde_cbor::from_slice(&bytes).unwrap();
        assert_eq!(decoded, request);
    }

    #[test]
    fn a_snapshot_round_trips_with_tracks() {
        let snapshot = PlaybackSnapshot {
            state: PlaybackState::Playing,
            media_item_id: Some("item-1".into()),
            episode_id: None,
            title: "Blade Runner".into(),
            subtitle: None,
            image_url: None,
            position_ms: 2_530_000,
            duration_ms: 6_960_000,
            volume: Some(0.8),
            muted: false,
            audio_tracks: vec![TrackInfo {
                id: "a1".into(),
                label: "English 5.1".into(),
                language: Some("eng".into()),
            }],
            subtitle_tracks: vec![],
            selected_audio: Some("a1".into()),
            selected_subtitle: None,
            capabilities: TargetCapabilities {
                volume: true,
                track_selection: true,
                next_previous: false,
            },
            sequence: 42,
        };

        let bytes = serde_cbor::to_vec(&snapshot).unwrap();
        let decoded: PlaybackSnapshot = serde_cbor::from_slice(&bytes).unwrap();
        assert_eq!(decoded, snapshot);
    }

    #[test]
    fn load_content_carries_a_reference_and_never_a_url() {
        let request = RemoteControlRequest::LoadContent(LoadContentRequest {
            media_item_id: "item-1".into(),
            episode_id: Some("ep-3".into()),
            position_ms: 0,
            audio_track: None,
            subtitle_track: None,
            autoplay: true,
        });
        let bytes = serde_cbor::to_vec(&request).unwrap();
        let decoded: RemoteControlRequest = serde_cbor::from_slice(&bytes).unwrap();
        assert_eq!(decoded, request);
    }
}
