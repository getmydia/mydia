//! The root mutation type.
//!
//! Every field here is a stub: it returns `None` or, for fields whose
//! silent absence would confuse a caller more than an explicit error,
//! `not_implemented`. None of them panic.

use async_graphql::{Context, Object, Result, ID};
use chrono::{DateTime, Utc};

use crate::context::not_implemented;
use crate::types::auth::{
    AccessToken, ApiKey, ClaimCode, CreateApiKeyResult, LoginInput, LoginResult, MediaToken,
    RevokeDeviceResult, ToggleFavoriteResult,
};
use crate::types::common::StreamingStrategy;
use crate::types::media::{Episode, Movie, Progress, TvShow};
use crate::types::streaming::{
    CancelDownloadResult, DownloadJobStatus, DownloadOption, PrepareDownloadResult,
    StreamingSessionResult,
};

pub struct RootMutationType;

#[Object(name = "RootMutationType")]
impl RootMutationType {
    /// Update playback progress for a movie
    async fn update_movie_progress(
        &self,
        _ctx: &Context<'_>,
        _movie_id: ID,
        _position_seconds: i32,
        _duration_seconds: Option<i32>,
    ) -> Result<Option<Progress>> {
        Ok(None)
    }

    /// Update playback progress for an episode
    async fn update_episode_progress(
        &self,
        _ctx: &Context<'_>,
        _episode_id: ID,
        _position_seconds: i32,
        _duration_seconds: Option<i32>,
    ) -> Result<Option<Progress>> {
        Ok(None)
    }

    /// Mark a movie as watched
    async fn mark_movie_watched(&self, _ctx: &Context<'_>, _movie_id: ID) -> Result<Option<Movie>> {
        Ok(None)
    }

    /// Mark a movie as unwatched
    async fn mark_movie_unwatched(
        &self,
        _ctx: &Context<'_>,
        _movie_id: ID,
    ) -> Result<Option<Movie>> {
        Ok(None)
    }

    /// Mark an episode as watched
    async fn mark_episode_watched(
        &self,
        _ctx: &Context<'_>,
        _episode_id: ID,
    ) -> Result<Option<Episode>> {
        Ok(None)
    }

    /// Mark an episode as unwatched
    async fn mark_episode_unwatched(
        &self,
        _ctx: &Context<'_>,
        _episode_id: ID,
    ) -> Result<Option<Episode>> {
        Ok(None)
    }

    /// Mark all episodes in a season as watched
    async fn mark_season_watched(
        &self,
        _ctx: &Context<'_>,
        _show_id: ID,
        _season_number: i32,
    ) -> Result<Option<TvShow>> {
        Ok(None)
    }

    /// Mark all episodes in a season as unwatched
    async fn mark_season_unwatched(
        &self,
        _ctx: &Context<'_>,
        _show_id: ID,
        _season_number: i32,
    ) -> Result<Option<TvShow>> {
        Ok(None)
    }

    /// Mark an episode and all earlier episodes in its season as watched
    async fn mark_episodes_up_to_watched(
        &self,
        _ctx: &Context<'_>,
        _episode_id: ID,
    ) -> Result<Option<TvShow>> {
        Ok(None)
    }

    /// Toggle favorite status for a media item
    async fn toggle_favorite(
        &self,
        _ctx: &Context<'_>,
        _media_item_id: ID,
    ) -> Result<Option<ToggleFavoriteResult>> {
        Ok(None)
    }

    /// Refresh a media access token before it expires
    async fn refresh_media_token(
        &self,
        _ctx: &Context<'_>,
        _token: String,
    ) -> Result<Option<MediaToken>> {
        Ok(None)
    }

    /// Exchange a pairing device token for a fresh access token
    async fn refresh_access_token(
        &self,
        _ctx: &Context<'_>,
        _device_token: String,
    ) -> Result<Option<AccessToken>> {
        Ok(None)
    }

    /// Generate a pairing claim code for device pairing (requires authentication)
    async fn generate_claim_code(&self, _ctx: &Context<'_>) -> Result<Option<ClaimCode>> {
        Err(not_implemented("generateClaimCode"))
    }

    /// Create a new API key for the current user
    async fn create_api_key(
        &self,
        _ctx: &Context<'_>,
        _name: String,
        _permissions: Option<Vec<String>>,
        _expires_at: Option<DateTime<Utc>>,
    ) -> Result<Option<CreateApiKeyResult>> {
        Ok(None)
    }

    /// Revoke an API key
    async fn revoke_api_key(&self, _ctx: &Context<'_>, _id: ID) -> Result<Option<ApiKey>> {
        Ok(None)
    }

    /// Delete an API key
    async fn delete_api_key(&self, _ctx: &Context<'_>, _id: ID) -> Result<Option<bool>> {
        Ok(None)
    }

    /// Login with username/password and device information
    async fn login(&self, _ctx: &Context<'_>, _input: LoginInput) -> Result<Option<LoginResult>> {
        Ok(None)
    }

    /// Revoke a device
    async fn revoke_device(
        &self,
        _ctx: &Context<'_>,
        _id: ID,
    ) -> Result<Option<RevokeDeviceResult>> {
        Ok(None)
    }

    /// Start an HLS streaming session for a media file
    async fn start_streaming_session(
        &self,
        _ctx: &Context<'_>,
        _file_id: ID,
        _strategy: StreamingStrategy,
        // Total kbps cap (video + audio), e.g. 2000
        _max_bitrate: Option<i32>,
        // Output height ceiling in pixels, e.g. 720. Preserves aspect ratio
        _max_height: Option<i32>,
        // Real media position, in seconds, at which to begin transcoding.
        // Optional; omitted or 0 starts at the beginning.
        _start_position: Option<i32>,
    ) -> Result<Option<StreamingSessionResult>> {
        Err(not_implemented("startStreamingSession"))
    }

    /// End an HLS streaming session
    async fn end_streaming_session(
        &self,
        _ctx: &Context<'_>,
        _session_id: String,
    ) -> Result<Option<bool>> {
        Err(not_implemented("endStreamingSession"))
    }

    /// Get available download quality options for a media item
    async fn download_options(
        &self,
        _ctx: &Context<'_>,
        // Content type: 'movie' or 'episode'
        _content_type: String,
        // Media item ID (for movie) or Episode ID (for episode)
        _id: ID,
    ) -> Result<Option<Vec<DownloadOption>>> {
        Ok(None)
    }

    /// Start or return existing transcode job for download
    async fn prepare_download(
        &self,
        _ctx: &Context<'_>,
        // Content type: 'movie' or 'episode'
        _content_type: String,
        // Media item ID (for movie) or Episode ID (for episode)
        _id: ID,
        // Target resolution
        _resolution: Option<String>,
    ) -> Result<Option<PrepareDownloadResult>> {
        Err(not_implemented("prepareDownload"))
    }

    /// Get current status and progress of a transcode job
    async fn download_job_status(
        &self,
        _ctx: &Context<'_>,
        // The transcode job ID
        _job_id: ID,
    ) -> Result<Option<DownloadJobStatus>> {
        Ok(None)
    }

    /// Cancel a transcode job
    async fn cancel_download_job(
        &self,
        _ctx: &Context<'_>,
        // The transcode job ID
        _job_id: ID,
    ) -> Result<Option<CancelDownloadResult>> {
        Err(not_implemented("cancelDownloadJob"))
    }
}
