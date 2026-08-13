//! Streaming and download types.
//!
//! Types owned by this module (keep in sync with tests/types_remaining.rs):
//! StreamingCandidatesResult, StreamingCandidate, StreamingMetadata,
//! StreamingSessionResult, DownloadOption, PrepareDownloadResult,
//! DownloadJobStatus, CancelDownloadResult.

use async_graphql::{SimpleObject, ID};

use crate::types::common::StreamingCandidateStrategy;

#[derive(SimpleObject)]
pub struct StreamingCandidatesResult {
    pub file_id: ID,
    pub candidates: Vec<StreamingCandidate>,
    pub metadata: StreamingMetadata,
}

#[derive(SimpleObject)]
pub struct StreamingCandidate {
    pub strategy: StreamingCandidateStrategy,
    pub mime: String,
    pub container: String,
    pub video_codec: Option<String>,
    pub audio_codec: Option<String>,
}

#[derive(SimpleObject)]
pub struct StreamingMetadata {
    pub duration: Option<f64>,
    pub width: Option<i32>,
    pub height: Option<i32>,
    pub bitrate: Option<i32>,
    pub resolution: Option<String>,
    pub hdr_format: Option<String>,
    pub original_codec: Option<String>,
    pub original_audio_codec: Option<String>,
    pub container: Option<String>,
    /// Audio languages the playback should prefer, most preferred first.
    ///
    /// Always `None` here for now, which the player reads as "this server has
    /// no opinion" and leaves mpv's own track selection alone — the behaviour
    /// this server already had. Answering properly needs two things it does
    /// not yet carry: the per-stream language tags (`MediaFileRow` stops at
    /// one flat `audio_codec`) and the layered `streaming.audio_language`
    /// config. The field exists regardless because `sdl_parity` gates on
    /// structure, and a query naming a field this schema lacks fails whole.
    pub preferred_audio_languages: Option<Vec<String>>,
}

#[derive(SimpleObject)]
pub struct StreamingSessionResult {
    pub session_id: String,
    pub duration: Option<f64>,
    pub start_position: Option<i32>,
    pub max_bitrate: Option<i32>,
    pub max_height: Option<i32>,
}

#[derive(SimpleObject)]
pub struct DownloadOption {
    pub resolution: String,
    pub label: String,
    pub estimated_size: i32,
    pub transcode_status: Option<String>,
    pub transcode_progress: Option<f64>,
    pub actual_size: Option<i32>,
}

#[derive(SimpleObject)]
pub struct PrepareDownloadResult {
    pub job_id: ID,
    pub status: String,
    pub progress: f64,
    pub file_size: Option<i32>,
}

#[derive(SimpleObject)]
pub struct DownloadJobStatus {
    pub job_id: ID,
    pub status: String,
    pub progress: f64,
    pub error: Option<String>,
    pub file_size: Option<i32>,
}

#[derive(SimpleObject)]
pub struct CancelDownloadResult {
    pub success: bool,
}

/// Renders just this group's types as SDL.
pub fn sdl_fragment() -> String {
    use async_graphql::{EmptyMutation, EmptySubscription, Object, Schema};

    struct FragmentQuery;

    #[Object]
    impl FragmentQuery {
        async fn streaming_candidates_result(&self) -> StreamingCandidatesResult {
            std::future::pending().await
        }

        async fn streaming_candidate(&self) -> StreamingCandidate {
            std::future::pending().await
        }

        async fn streaming_metadata(&self) -> StreamingMetadata {
            std::future::pending().await
        }

        async fn streaming_session_result(&self) -> StreamingSessionResult {
            std::future::pending().await
        }

        async fn download_option(&self) -> DownloadOption {
            std::future::pending().await
        }

        async fn prepare_download_result(&self) -> PrepareDownloadResult {
            std::future::pending().await
        }

        async fn download_job_status(&self) -> DownloadJobStatus {
            std::future::pending().await
        }

        async fn cancel_download_result(&self) -> CancelDownloadResult {
            std::future::pending().await
        }
    }

    Schema::build(FragmentQuery, EmptyMutation, EmptySubscription)
        .finish()
        .sdl()
}
