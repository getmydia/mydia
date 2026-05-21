//! Playback mutations — port of
//! `lib/mydia_web/schema/resolvers/playback_resolver.ex`.
//!
//! Eight mutations live here:
//!
//! - `updateMovieProgress`, `updateEpisodeProgress`
//! - `markMovieWatched`, `markMovieUnwatched`
//! - `markEpisodeWatched`, `markEpisodeUnwatched`
//! - `markSeasonWatched`
//! - `toggleFavorite`
//!
//! All require an authenticated `current_user`. Progress writes
//! publish on the per-node pubsub topic that **IS the encoded global
//! node ID of the media item being progressed**, matching Phoenix's
//! `Absinthe.Subscription.publish(..., progress_updated: <id>)` shape.
//! U12 subscribes from the same topics; the bus comes from
//! [`GraphqlAppState::pubsub`].

use async_graphql::{Context, Object, ID};

use crate::context::{CurrentUser, GraphqlAppState};
use crate::node_id::{NodeId, NodeRef};
use crate::repos::{collections, media, playback};
use crate::types::{Episode, Movie, Progress, ToggleFavoriteResult, TvShow};

/// Shape of the broadcast payload published on each progress write.
/// Mirrors the `:progress` GraphQL object so subscribers don't have
/// to re-shape it. Serialized to JSON inside the pubsub Event.
#[derive(Debug, Clone, serde::Serialize)]
pub struct ProgressEvent {
    pub position_seconds: i32,
    pub duration_seconds: i32,
    pub percentage: f64,
    pub watched: bool,
    pub last_watched_at: chrono::DateTime<chrono::Utc>,
}

#[derive(Default)]
pub struct PlaybackMutations;

#[Object]
impl PlaybackMutations {
    /// Upsert progress for a movie. Returns the new progress shape.
    async fn update_movie_progress(
        &self,
        ctx: &Context<'_>,
        movie_id: ID,
        position_seconds: i32,
        duration_seconds: Option<i32>,
    ) -> async_graphql::Result<Progress> {
        let user = require_user(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;
        let raw_id = decode_id(movie_id.as_str(), "movie")?;
        let update = playback::ProgressUpsert {
            position_seconds: Some(position_seconds),
            duration_seconds,
            last_watched_at: None,
            watched_override: None,
        };
        let row = playback::upsert_progress(
            &state.db,
            &user.id.to_string(),
            playback::Parent::MediaItem(&raw_id),
            update,
        )
        .await
        .map_err(format_progress_error)?;

        let event = build_progress_event(&row);
        broadcast_progress(state, &progress_topic_movie(&raw_id), &event);
        Ok(progress_from_row(&row))
    }

    /// Upsert progress for an episode.
    async fn update_episode_progress(
        &self,
        ctx: &Context<'_>,
        episode_id: ID,
        position_seconds: i32,
        duration_seconds: Option<i32>,
    ) -> async_graphql::Result<Progress> {
        let user = require_user(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;
        let raw_id = decode_id(episode_id.as_str(), "episode")?;
        let update = playback::ProgressUpsert {
            position_seconds: Some(position_seconds),
            duration_seconds,
            last_watched_at: None,
            watched_override: None,
        };
        let row = playback::upsert_progress(
            &state.db,
            &user.id.to_string(),
            playback::Parent::Episode(&raw_id),
            update,
        )
        .await
        .map_err(format_progress_error)?;

        let event = build_progress_event(&row);
        broadcast_progress(state, &progress_topic_episode(&raw_id), &event);
        Ok(progress_from_row(&row))
    }

    /// Mark a movie as watched. Creates a progress row with
    /// `(position=0, duration=1, watched=true)` if none exists yet,
    /// matching Phoenix's fallback path.
    async fn mark_movie_watched(
        &self,
        ctx: &Context<'_>,
        movie_id: ID,
    ) -> async_graphql::Result<Movie> {
        let user = require_user(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;
        let raw_id = decode_id(movie_id.as_str(), "movie")?;

        let parent = playback::Parent::MediaItem(&raw_id);
        if playback::mark_watched(&state.db, &user.id.to_string(), parent)
            .await?
            .is_none()
        {
            // Phoenix's "create watched progress if it doesn't exist"
            // fallback (playback_resolver.ex:87-99).
            playback::upsert_progress(
                &state.db,
                &user.id.to_string(),
                parent,
                playback::ProgressUpsert {
                    position_seconds: Some(0),
                    duration_seconds: Some(1),
                    last_watched_at: None,
                    watched_override: Some(true),
                },
            )
            .await
            .map_err(format_progress_error)?;
        }
        load_movie(state, &raw_id).await
    }

    /// Mark a movie as unwatched. Deletes the progress row if it
    /// exists; otherwise no-op (matches Phoenix's
    /// `delete_progress -> {:error, :not_found}` no-op branch).
    async fn mark_movie_unwatched(
        &self,
        ctx: &Context<'_>,
        movie_id: ID,
    ) -> async_graphql::Result<Movie> {
        let user = require_user(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;
        let raw_id = decode_id(movie_id.as_str(), "movie")?;
        playback::delete_progress(
            &state.db,
            &user.id.to_string(),
            playback::Parent::MediaItem(&raw_id),
        )
        .await?;
        load_movie(state, &raw_id).await
    }

    /// Mark an episode as watched.
    async fn mark_episode_watched(
        &self,
        ctx: &Context<'_>,
        episode_id: ID,
    ) -> async_graphql::Result<Episode> {
        let user = require_user(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;
        let raw_id = decode_id(episode_id.as_str(), "episode")?;

        let parent = playback::Parent::Episode(&raw_id);
        if playback::mark_watched(&state.db, &user.id.to_string(), parent)
            .await?
            .is_none()
        {
            playback::upsert_progress(
                &state.db,
                &user.id.to_string(),
                parent,
                playback::ProgressUpsert {
                    position_seconds: Some(0),
                    duration_seconds: Some(1),
                    last_watched_at: None,
                    watched_override: Some(true),
                },
            )
            .await
            .map_err(format_progress_error)?;
        }
        load_episode(state, &raw_id).await
    }

    /// Mark an episode as unwatched.
    async fn mark_episode_unwatched(
        &self,
        ctx: &Context<'_>,
        episode_id: ID,
    ) -> async_graphql::Result<Episode> {
        let user = require_user(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;
        let raw_id = decode_id(episode_id.as_str(), "episode")?;
        playback::delete_progress(
            &state.db,
            &user.id.to_string(),
            playback::Parent::Episode(&raw_id),
        )
        .await?;
        load_episode(state, &raw_id).await
    }

    /// Mark every episode in a season as watched.
    async fn mark_season_watched(
        &self,
        ctx: &Context<'_>,
        show_id: ID,
        season_number: i32,
    ) -> async_graphql::Result<TvShow> {
        let user = require_user(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;
        let raw_show_id = decode_id(show_id.as_str(), "show")?;

        let episodes = media::list_episodes(&state.db, &raw_show_id).await?;
        for ep in episodes
            .iter()
            .filter(|e| e.season_number == Some(season_number))
        {
            let ep_id_str = ep.id.0.to_string();
            let parent = playback::Parent::Episode(&ep_id_str);
            if playback::mark_watched(&state.db, &user.id.to_string(), parent)
                .await?
                .is_none()
            {
                playback::upsert_progress(
                    &state.db,
                    &user.id.to_string(),
                    parent,
                    playback::ProgressUpsert {
                        position_seconds: Some(0),
                        duration_seconds: Some(1),
                        last_watched_at: None,
                        watched_override: Some(true),
                    },
                )
                .await
                .map_err(format_progress_error)?;
            }
        }
        load_tv_show(state, &raw_show_id).await
    }

    /// Toggle a media item's membership in the user's favorites.
    async fn toggle_favorite(
        &self,
        ctx: &Context<'_>,
        media_item_id: ID,
    ) -> async_graphql::Result<ToggleFavoriteResult> {
        let user = require_user(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;
        let raw_id = decode_any_id(media_item_id.as_str())?;
        let outcome =
            collections::toggle_favorite(&state.db, &user.id.to_string(), &raw_id).await?;
        Ok(ToggleFavoriteResult {
            is_favorite: matches!(outcome, collections::ToggleOutcome::Added),
            media_item_id,
        })
    }
}

fn require_user<'a>(ctx: &'a Context<'_>) -> async_graphql::Result<&'a CurrentUser> {
    ctx.data_opt::<crate::context::GraphqlRequestContext>()
        .and_then(|r| r.current_user.as_ref())
        .ok_or_else(|| async_graphql::Error::new("Authentication required"))
}

/// Decode a global ID expected to be of a particular type. Accepts
/// raw UUIDs as well (Phoenix permissively accepts both forms).
fn decode_id(input: &str, expected_tag: &str) -> async_graphql::Result<String> {
    if let Ok(node) = NodeId::decode(input) {
        if node.type_tag() != expected_tag {
            return Err(async_graphql::Error::new(format!(
                "Invalid {expected_tag} id"
            )));
        }
        Ok(node_ref_to_string(node))
    } else if input.is_empty() {
        Err(async_graphql::Error::new("Empty id"))
    } else {
        Ok(input.to_owned())
    }
}

/// Decode an ID without enforcing a tag — `toggleFavorite` accepts
/// movies or TV shows.
fn decode_any_id(input: &str) -> async_graphql::Result<String> {
    if let Ok(node) = NodeId::decode(input) {
        Ok(node_ref_to_string(node))
    } else if input.is_empty() {
        Err(async_graphql::Error::new("Empty id"))
    } else {
        Ok(input.to_owned())
    }
}

fn node_ref_to_string(node: NodeId) -> String {
    match node {
        NodeId::Movie(NodeRef::Str(s))
        | NodeId::TvShow(NodeRef::Str(s))
        | NodeId::Episode(NodeRef::Str(s))
        | NodeId::LibraryPath(NodeRef::Str(s)) => s,
        NodeId::Movie(NodeRef::Int(n))
        | NodeId::TvShow(NodeRef::Int(n))
        | NodeId::Episode(NodeRef::Int(n))
        | NodeId::LibraryPath(NodeRef::Int(n)) => n.to_string(),
        NodeId::Season { show_id, .. } => match show_id {
            NodeRef::Str(s) => s,
            NodeRef::Int(n) => n.to_string(),
        },
    }
}

async fn load_movie(state: &GraphqlAppState, id: &str) -> async_graphql::Result<Movie> {
    let row = media::get_media_item(&state.db, id)
        .await?
        .ok_or_else(|| async_graphql::Error::new("Movie not found"))?;
    Movie::from_row(&row).ok_or_else(|| async_graphql::Error::new("Not a movie"))
}

async fn load_tv_show(state: &GraphqlAppState, id: &str) -> async_graphql::Result<TvShow> {
    let row = media::get_media_item(&state.db, id)
        .await?
        .ok_or_else(|| async_graphql::Error::new("TV show not found"))?;
    TvShow::from_row(&row).ok_or_else(|| async_graphql::Error::new("Not a TV show"))
}

async fn load_episode(state: &GraphqlAppState, id: &str) -> async_graphql::Result<Episode> {
    let row = media::get_episode(&state.db, id)
        .await?
        .ok_or_else(|| async_graphql::Error::new("Episode not found"))?;
    Ok(Episode::from_row(&row))
}

fn progress_from_row(row: &playback::ProgressRow) -> Progress {
    Progress {
        position_seconds: row.position_seconds,
        duration_seconds: Some(row.duration_seconds),
        percentage: Some(row.completion_percentage),
        watched: row.watched,
        last_watched_at: Some(row.last_watched_at.0),
    }
}

fn build_progress_event(row: &playback::ProgressRow) -> ProgressEvent {
    ProgressEvent {
        position_seconds: row.position_seconds,
        duration_seconds: row.duration_seconds,
        percentage: row.completion_percentage,
        watched: row.watched,
        last_watched_at: row.last_watched_at.0,
    }
}

fn broadcast_progress(state: &GraphqlAppState, topic: &str, event: &ProgressEvent) {
    match mydia_rs_pubsub::Event::from_serializable(event) {
        Ok(payload) => {
            state.pubsub.publish(topic, payload);
        }
        Err(err) => {
            tracing::warn!(
                target: "mydia_rs_graphql::playback",
                error = %err,
                "failed to serialize progress event"
            );
        }
    }
}

/// Topic name for movie progress events — the encoded movie:<uuid>
/// global node ID. Mirrors Phoenix's `topic: args.node_id` shape from
/// `lib/mydia_web/schema/subscription_types.ex`. The Phoenix resolver
/// publishes with the raw UUID (`progress_updated: movie_id`); the
/// Rust port publishes on the encoded form to match U12's
/// subscription contract — the harness in U13 surfaces any drift.
fn progress_topic_movie(uuid: &str) -> String {
    NodeId::Movie(NodeRef::Str(uuid.to_owned())).encode()
}

fn progress_topic_episode(uuid: &str) -> String {
    NodeId::Episode(NodeRef::Str(uuid.to_owned())).encode()
}

/// Map `playback::ProgressError` into the equivalent
/// `async_graphql::Error` shape Phoenix's `format_changeset_errors`
/// produces.
fn format_progress_error(err: playback::ProgressError) -> async_graphql::Error {
    match err {
        playback::ProgressError::Db(e) => async_graphql::Error::new(e.to_string()),
        other => async_graphql::Error::new(other.to_string()),
    }
}
