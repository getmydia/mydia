//! Streaming candidate query — port of
//! `StreamingResolver.streaming_candidates/3`. The query takes a
//! `content_type` ("movie", "episode", or "file") plus an `id` and
//! returns the prioritized list of strategies the client can use to
//! play it, alongside source metadata.
//!
//! The Phoenix implementation delegates to
//! `Mydia.Streaming.Candidates`, which inspects ffprobe-derived
//! metadata on the file row to decide between direct-play / remux /
//! HLS-copy / transcode. **The full Candidates logic lands in U19.**
//! Until then, this resolver returns a single-element "transcode"
//! candidate plus whatever metadata can be pulled directly from the
//! `media_files` row. The Flutter player still receives a well-typed
//! response and the schema shape stays stable for the parity replay
//! harness in U13.

use async_graphql::{Context, Object, ID};

use crate::context::GraphqlAppState;
use crate::repos::media;
use crate::types::{
    StreamingCandidate, StreamingCandidateStrategy, StreamingCandidatesResult, StreamingMetadata,
};

#[derive(Default)]
pub struct StreamingQueries;

#[Object]
impl StreamingQueries {
    /// Resolve a media file from a (content_type, id) pair and return
    /// the streaming-strategy candidates plus source metadata. Calls
    /// fail with `Authentication required` when no user is in context.
    async fn streaming_candidates(
        &self,
        ctx: &Context<'_>,
        content_type: String,
        id: ID,
    ) -> async_graphql::Result<StreamingCandidatesResult> {
        ensure_authenticated(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;
        let media_file = resolve_media_file(state, &content_type, id.as_str())
            .await?
            .ok_or_else(|| async_graphql::Error::new(format!("{content_type} not found")))?;

        let metadata = build_metadata(&media_file);
        // U11 stub: surface a single TRANSCODE candidate so the
        // schema shape is correct end-to-end. U19's Candidates module
        // replaces this with the real priority list.
        let candidates = vec![StreamingCandidate {
            strategy: StreamingCandidateStrategy::Transcode,
            mime: "application/vnd.apple.mpegurl".into(),
            container: "hls".into(),
            video_codec: media_file.codec.clone(),
            audio_codec: media_file.audio_codec.clone(),
        }];

        Ok(StreamingCandidatesResult {
            file_id: ID(media_file.id.0.to_string()),
            candidates,
            metadata,
        })
    }
}

fn ensure_authenticated(ctx: &Context<'_>) -> async_graphql::Result<()> {
    let request_ctx = ctx.data_opt::<crate::context::GraphqlRequestContext>();
    let is_authed = request_ctx.is_some_and(|r| r.current_user.is_some());
    if is_authed {
        Ok(())
    } else {
        Err(async_graphql::Error::new("Authentication required"))
    }
}

async fn resolve_media_file(
    state: &GraphqlAppState,
    content_type: &str,
    id: &str,
) -> async_graphql::Result<Option<mydia_rs_models::MediaFile>> {
    match content_type {
        "movie" => Ok(media::first_media_file_for_movie(&state.db, id).await?),
        "episode" => Ok(media::first_media_file_for_episode(&state.db, id).await?),
        "file" => Ok(media::get_media_file(&state.db, id).await?),
        other => Err(async_graphql::Error::new(format!(
            "Invalid content type '{other}'. Use 'movie', 'episode', or 'file'"
        ))),
    }
}

fn build_metadata(file: &mydia_rs_models::MediaFile) -> StreamingMetadata {
    let raw = file.metadata.as_ref().map(|m| &m.0);
    StreamingMetadata {
        duration: raw.and_then(|m| m.get("duration").and_then(|v| v.as_f64())),
        width: raw.and_then(|m| m.get("width").and_then(|v| v.as_i64()).map(|n| n as i32)),
        height: raw.and_then(|m| m.get("height").and_then(|v| v.as_i64()).map(|n| n as i32)),
        bitrate: file
            .bitrate
            .or_else(|| raw.and_then(|m| m.get("bit_rate").and_then(|v| v.as_i64()))),
        resolution: file.resolution.clone(),
        hdr_format: file.hdr_format.clone(),
        original_codec: file.codec.clone(),
        original_audio_codec: file.audio_codec.clone(),
        container: raw.and_then(|m| {
            m.get("container")
                .and_then(|v| v.as_str())
                .map(|s| s.to_owned())
        }),
    }
}
