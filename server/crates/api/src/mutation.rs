//! The root mutation type.
//!
//! Every field here is a stub: it returns `None` or, for fields whose
//! silent absence would confuse a caller more than an explicit error,
//! `not_implemented`. None of them panic.

use async_graphql::{Context, Error, ErrorExtensions, Object, Result, ID};
use chrono::{DateTime, Utc};
use mydia_auth::tokens::TokenKind;

use crate::context::{authenticated_user, not_implemented, ApiContext};
use crate::types::auth::{
    remote_device_from, AccessToken, ApiKey, ClaimCode, CreateApiKeyResult, LoginInput,
    LoginResult, MediaToken, RevokeDeviceResult, ToggleFavoriteResult, User,
};
use crate::types::common::StreamingStrategy;
use crate::types::discovery::RemoveFromContinueWatchingResult;
use crate::types::media::{Episode, Movie, Progress, SubtitleTrack, TvShow};
use crate::types::streaming::{
    AudioLanguagePreferenceResult, CancelDownloadResult, DownloadJobStatus, DownloadOption,
    PrepareDownloadResult, StreamingSessionResult,
};

/// A wrong username and a wrong password produce the same message, so the
/// response does not reveal which usernames exist.
fn invalid_credentials() -> Error {
    Error::new("The username or password is not correct")
        .extend_with(|_, e| e.set("code", "INVALID_CREDENTIALS"))
}

/// A malformed or expired token, wherever it is presented.
fn invalid_token() -> Error {
    Error::new("The token is invalid or has expired")
        .extend_with(|_, e| e.set("code", "INVALID_TOKEN"))
}

/// The caller tried to act on a device that is not theirs.
fn forbidden() -> Error {
    Error::new("You do not have access to this device")
        .extend_with(|_, e| e.set("code", "FORBIDDEN"))
}

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

    /// Download a subtitle candidate returned by subtitleSearch.
    ///
    /// mutation_types.ex:`:download_subtitle`. This server acquires no media,
    /// and `subtitleSearch` here never returns a candidate, so any token
    /// reaching this field came from somewhere else. The return type is
    /// non-null, so an explicit error is the only honest answer available.
    async fn download_subtitle(
        &self,
        ctx: &Context<'_>,
        _media_file_id: ID,
        _token: String,
    ) -> Result<SubtitleTrack> {
        authenticated_user(ctx).await?;

        Err(not_implemented("downloadSubtitle"))
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

    /// Hide a movie or show from Continue Watching until it is played again
    async fn remove_from_continue_watching(
        &self,
        _ctx: &Context<'_>,
        _media_item_id: ID,
    ) -> Result<Option<RemoveFromContinueWatchingResult>> {
        Ok(None)
    }

    /// Refresh a media access token before it expires
    async fn refresh_media_token(
        &self,
        ctx: &Context<'_>,
        token: String,
    ) -> Result<Option<MediaToken>> {
        let api = ctx.data::<ApiContext>()?;

        let claims = api
            .issuer
            .verify(&token, TokenKind::Media)
            .map_err(|_| invalid_token())?;

        let (new_token, expires_at) = api
            .issuer
            .issue(&claims.sub, TokenKind::Media, claims.permissions.clone())
            .map_err(|e| Error::new(e.to_string()))?;

        Ok(Some(MediaToken {
            token: new_token,
            expires_at,
            permissions: claims.permissions,
        }))
    }

    /// Exchange a pairing device token for a fresh access token
    async fn refresh_access_token(
        &self,
        ctx: &Context<'_>,
        device_token: String,
    ) -> Result<Option<AccessToken>> {
        let api = ctx.data::<ApiContext>()?;

        let claims = api
            .issuer
            .verify(&device_token, TokenKind::Refresh)
            .map_err(|_| invalid_token())?;

        let user = mydia_db::users::find_by_id(&api.db, &claims.sub)
            .await
            .map_err(|e| Error::new(e.to_string()))?
            .ok_or_else(invalid_token)?;

        let (token, expires_at) = api
            .issuer
            .issue(&user.id, TokenKind::Access, vec![])
            .map_err(|e| Error::new(e.to_string()))?;

        Ok(Some(AccessToken { token, expires_at }))
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
    async fn login(&self, ctx: &Context<'_>, input: LoginInput) -> Result<Option<LoginResult>> {
        let api = ctx.data::<ApiContext>()?;

        let user = mydia_db::users::find_by_username(&api.db, &input.username)
            .await
            .map_err(|e| Error::new(e.to_string()))?
            .ok_or_else(invalid_credentials)?;

        if !mydia_auth::password::verify(&input.password, &user.password_hash) {
            return Err(invalid_credentials());
        }

        mydia_db::devices::upsert(
            &api.db,
            mydia_db::devices::NewDevice {
                user_id: user.id.clone(),
                device_id: input.device_id,
                device_name: input.device_name,
                platform: input.platform,
            },
        )
        .await
        .map_err(|e| Error::new(e.to_string()))?;

        let (token, expires_at) = api
            .issuer
            .issue(&user.id, TokenKind::Access, vec![])
            .map_err(|e| Error::new(e.to_string()))?;

        let expires_in = (expires_at - Utc::now()).num_seconds() as i32;

        Ok(Some(LoginResult {
            token,
            user: User {
                id: user.id.into(),
                username: Some(user.username),
                email: user.email,
                display_name: user.display_name,
            },
            expires_in,
        }))
    }

    /// Revoke a device
    ///
    /// This only records the device as revoked; it does not yet invalidate
    /// tokens already issued to that device. Tokens are not device-bound in
    /// this slice, so a revoked device's existing access/refresh tokens
    /// remain valid until they expire. Enforcing revocation on the auth path
    /// is a later slice.
    async fn revoke_device(&self, ctx: &Context<'_>, id: ID) -> Result<Option<RevokeDeviceResult>> {
        let api = ctx.data::<ApiContext>()?;
        let user = authenticated_user(ctx).await?;

        let device = mydia_db::devices::revoke_for_user(&api.db, &user.id, &id)
            .await
            .map_err(|e| Error::new(e.to_string()))?;

        let Some(device) = device else {
            return Err(forbidden());
        };

        Ok(Some(RevokeDeviceResult {
            success: true,
            device: Some(remote_device_from(device)?),
        }))
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

    /// Remember which audio language this viewer wants for a show or film
    async fn set_audio_language_preference(
        &self,
        _ctx: &Context<'_>,
        // Any file of the show or film; the preference is stored against the
        // item it belongs to.
        _file_id: ID,
        // Language code to remember. Null forgets the choice.
        _language: Option<String>,
    ) -> Result<Option<AudioLanguagePreferenceResult>> {
        Err(not_implemented("setAudioLanguagePreference"))
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
