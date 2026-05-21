//! Real-time Trakt playback scrobbler.
//!
//! Port of `lib/mydia/integrations/trakt/scrobbler.ex`. The Phoenix
//! module wraps `Task.Supervisor.start_child` around the actual HTTP
//! call so the playback resolver stays non-blocking. In Rust the
//! caller's responsibility — playback resolvers `tokio::spawn` a
//! detached future that calls these helpers.

use serde::Serialize;

use crate::error::IntegrationError;
use crate::trakt::client::TraktClient;
use crate::trakt::sync::LocalMediaItem;

/// One scrobble action. Maps to `/trakt/scrobble/<action>`.
#[derive(Debug, Clone, Copy)]
pub enum ScrobbleAction {
    Start,
    Pause,
    Stop,
}

/// Identifies what's being scrobbled. Either a movie or an episode
/// inside a show.
#[derive(Debug, Clone)]
pub enum ScrobbleTarget {
    Movie {
        item: LocalMediaItem,
    },
    Episode {
        show: LocalMediaItem,
        season_number: i32,
        episode_number: i32,
    },
}

/// Build the request body for a scrobble call.
///
/// Returns `None` when the target has no Trakt-recognizable external
/// IDs — same gate Phoenix applies via `maybe_put_ids`.
#[must_use]
pub fn build_scrobble_body(target: &ScrobbleTarget, progress_pct: f64) -> Option<ScrobbleBody> {
    match target {
        ScrobbleTarget::Movie { item } => {
            let movie = MovieRef::from_item(item)?;
            Some(ScrobbleBody::Movie {
                movie,
                progress: progress_pct,
            })
        }
        ScrobbleTarget::Episode {
            show,
            season_number,
            episode_number,
        } => {
            let show_ref = ShowRef::from_item(show)?;
            Some(ScrobbleBody::Episode {
                show: show_ref,
                episode: EpisodeRef {
                    season: *season_number,
                    number: *episode_number,
                },
                progress: progress_pct,
            })
        }
    }
}

/// Send a scrobble request via the relay.
///
/// Fire-and-forget pattern from Phoenix: the playback resolver should
/// spawn this and ignore the future (errors logged via `tracing`).
pub async fn scrobble(
    client: &TraktClient,
    action: ScrobbleAction,
    user_token: &str,
    body: &ScrobbleBody,
) -> Result<serde_json::Value, IntegrationError> {
    let body_value = serde_json::to_value(body)?;
    match action {
        ScrobbleAction::Start => client.scrobble_start(&body_value, user_token).await,
        ScrobbleAction::Pause => client.scrobble_pause(&body_value, user_token).await,
        ScrobbleAction::Stop => client.scrobble_stop(&body_value, user_token).await,
    }
}

/// Body shapes the relay accepts for `/trakt/scrobble/*`.
#[derive(Debug, Clone, Serialize)]
#[serde(untagged)]
pub enum ScrobbleBody {
    Movie {
        movie: MovieRef,
        progress: f64,
    },
    Episode {
        show: ShowRef,
        episode: EpisodeRef,
        progress: f64,
    },
}

#[derive(Debug, Clone, Serialize)]
pub struct MovieRef {
    pub title: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub year: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ids: Option<serde_json::Map<String, serde_json::Value>>,
}

#[derive(Debug, Clone, Serialize)]
pub struct ShowRef {
    pub title: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub year: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ids: Option<serde_json::Map<String, serde_json::Value>>,
}

#[derive(Debug, Clone, Serialize)]
pub struct EpisodeRef {
    pub season: i32,
    pub number: i32,
}

impl MovieRef {
    fn from_item(item: &LocalMediaItem) -> Option<Self> {
        let ids = crate::trakt::client::build_ids(
            item.imdb_id.as_deref(),
            item.tmdb_id.as_deref(),
            item.tvdb_id.as_deref(),
        );
        // A scrobble can still go through with `null` ids if the relay
        // accepts it, but Phoenix only sends scrobbles when at least one
        // ID is present, so we mirror that gate.
        ids.as_ref()?;
        Some(Self {
            title: item.title.clone(),
            year: item.year,
            ids,
        })
    }
}

impl ShowRef {
    fn from_item(item: &LocalMediaItem) -> Option<Self> {
        let ids = crate::trakt::client::build_ids(
            item.imdb_id.as_deref(),
            item.tmdb_id.as_deref(),
            item.tvdb_id.as_deref(),
        );
        ids.as_ref()?;
        Some(Self {
            title: item.title.clone(),
            year: item.year,
            ids,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item_with_ids() -> LocalMediaItem {
        LocalMediaItem {
            id: "abc".into(),
            title: "Inception".into(),
            year: Some(2010),
            imdb_id: Some("tt1375666".into()),
            tmdb_id: None,
            tvdb_id: None,
        }
    }

    fn item_without_ids() -> LocalMediaItem {
        LocalMediaItem {
            id: "abc".into(),
            title: "Unknown".into(),
            year: None,
            imdb_id: None,
            tmdb_id: None,
            tvdb_id: None,
        }
    }

    #[test]
    fn movie_body_includes_progress() {
        let body = build_scrobble_body(
            &ScrobbleTarget::Movie {
                item: item_with_ids(),
            },
            42.0,
        )
        .unwrap();
        let json = serde_json::to_value(&body).unwrap();
        assert_eq!(json.get("progress").unwrap(), 42.0);
        assert!(json.get("movie").is_some());
    }

    #[test]
    fn episode_body_includes_season_number() {
        let body = build_scrobble_body(
            &ScrobbleTarget::Episode {
                show: item_with_ids(),
                season_number: 2,
                episode_number: 5,
            },
            10.0,
        )
        .unwrap();
        let json = serde_json::to_value(&body).unwrap();
        assert_eq!(json.get("episode").unwrap().get("season").unwrap(), 2);
        assert_eq!(json.get("episode").unwrap().get("number").unwrap(), 5);
    }

    #[test]
    fn item_without_ids_yields_no_body() {
        let result = build_scrobble_body(
            &ScrobbleTarget::Movie {
                item: item_without_ids(),
            },
            0.0,
        );
        assert!(result.is_none());
    }
}
