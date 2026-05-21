//! Bidirectional watched-status sync orchestrator.
//!
//! Port of `lib/mydia/media_server/watched_sync.ex` +
//! `watched_sync/orchestrator.ex` + `watched_sync/plex.ex`.
//!
//! Conflict-resolution policy (mirrored from Phoenix): **watched wins**.
//! If an item is watched on either side, it gets marked as watched on
//! both. Unwatch is never propagated.

use std::collections::BTreeMap;

use async_trait::async_trait;
use tracing::warn;

use crate::error::IntegrationError;
use crate::media_server::client::{MediaServerConfig, MediaServerKind};
use crate::media_server::plex::{PlexClient, PlexEpisode, PlexSection};

/// One watched item reported by a media server.
#[derive(Debug, Clone)]
pub struct WatchedItem {
    pub kind: WatchedItemKind,
    /// Provider → external ID. `tmdb` / `imdb` / `tvdb`.
    pub external_ids: BTreeMap<String, String>,
    pub title: String,
    pub season_number: Option<i32>,
    pub episode_number: Option<i32>,
    /// Opaque server-side ID — what `mark_watched` / `mark_unwatched`
    /// take to identify the item on the server.
    pub server_item_id: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WatchedItemKind {
    Movie,
    Episode,
}

/// Adapter behaviour every supported media-server kind implements.
#[async_trait]
pub trait WatchedSyncAdapter: Send + Sync {
    /// Fetch every watched item from the server.
    async fn fetch_watched(
        &self,
        config: &MediaServerConfig,
    ) -> Result<Vec<WatchedItem>, IntegrationError>;

    /// Mark one server item as watched.
    async fn mark_watched(
        &self,
        config: &MediaServerConfig,
        server_item_id: &str,
    ) -> Result<(), IntegrationError>;

    /// Mark one server item as unwatched.
    async fn mark_unwatched(
        &self,
        config: &MediaServerConfig,
        server_item_id: &str,
    ) -> Result<(), IntegrationError>;

    /// Build an index of `{kind}:{provider}:{external_id}[:s{NN}e{NN}]`
    /// → `server_item_id`. Used by export to look up server IDs for
    /// locally-watched items.
    async fn build_server_index(
        &self,
        config: &MediaServerConfig,
    ) -> Result<BTreeMap<String, String>, IntegrationError>;
}

/// Pick the watched-sync adapter for a given config. Phoenix only
/// supports Plex today; Jellyfin / Emby will error out at the same
/// place the Phoenix code does.
pub fn adapter_for(
    plex: &PlexClient,
    config: &MediaServerConfig,
) -> Result<PlexWatchedSync, IntegrationError> {
    match config.kind {
        MediaServerKind::Plex => Ok(PlexWatchedSync::new(plex.clone())),
        other => Err(IntegrationError::invalid_config(format!(
            "Watched sync not supported for {other:?}"
        ))),
    }
}

/// Plex implementation of [`WatchedSyncAdapter`].
#[derive(Debug, Clone)]
pub struct PlexWatchedSync {
    client: PlexClient,
}

impl PlexWatchedSync {
    pub fn new(client: PlexClient) -> Self {
        Self { client }
    }

    async fn fetch_section(
        &self,
        config: &MediaServerConfig,
        section: &PlexSection,
    ) -> Vec<WatchedItem> {
        match section.kind.as_str() {
            "movie" => match self.client.list_section_items(config, &section.key).await {
                Ok(items) => items
                    .into_iter()
                    .filter(|i| i.view_count > 0)
                    .map(|item| WatchedItem {
                        kind: WatchedItemKind::Movie,
                        external_ids: item.guids,
                        title: item.title,
                        season_number: None,
                        episode_number: None,
                        server_item_id: item.rating_key,
                    })
                    .collect(),
                Err(err) => {
                    warn!(section = %section.key, %err, "Failed to fetch Plex movie section");
                    Vec::new()
                }
            },
            "show" => match self.client.list_section_items(config, &section.key).await {
                Ok(shows) => {
                    let mut out = Vec::new();
                    for show in shows {
                        match self
                            .client
                            .list_show_episodes(config, &show.rating_key)
                            .await
                        {
                            Ok(episodes) => {
                                for ep in episodes.into_iter().filter(|e| e.view_count > 0) {
                                    out.push(WatchedItem {
                                        kind: WatchedItemKind::Episode,
                                        external_ids: show.guids.clone(),
                                        title: format_episode_title(&show.title, &ep),
                                        season_number: ep.season_number,
                                        episode_number: ep.episode_number,
                                        server_item_id: ep.rating_key,
                                    });
                                }
                            }
                            Err(err) => {
                                warn!(show = %show.title, %err, "Failed to fetch episodes");
                            }
                        }
                    }
                    out
                }
                Err(err) => {
                    warn!(section = %section.key, %err, "Failed to fetch Plex show section");
                    Vec::new()
                }
            },
            other => {
                tracing::debug!(kind = %other, section = %section.key, "Skipping unsupported Plex section");
                Vec::new()
            }
        }
    }

    async fn index_section(
        &self,
        config: &MediaServerConfig,
        section: &PlexSection,
    ) -> Vec<(String, String)> {
        match section.kind.as_str() {
            "movie" => match self.client.list_section_items(config, &section.key).await {
                Ok(items) => items
                    .into_iter()
                    .flat_map(|item| build_index_entries("movie", &item.guids, &item.rating_key))
                    .collect(),
                Err(err) => {
                    warn!(section = %section.key, %err, "Failed to index Plex movie section");
                    Vec::new()
                }
            },
            "show" => match self.client.list_section_items(config, &section.key).await {
                Ok(shows) => {
                    let mut out = Vec::new();
                    for show in shows {
                        match self
                            .client
                            .list_show_episodes(config, &show.rating_key)
                            .await
                        {
                            Ok(episodes) => {
                                for ep in episodes {
                                    let suffix = format_episode_suffix(&ep);
                                    for (provider, id) in &show.guids {
                                        out.push((
                                            format!("episode:{provider}:{id}:{suffix}",),
                                            ep.rating_key.clone(),
                                        ));
                                    }
                                }
                            }
                            Err(err) => {
                                warn!(show = %show.title, %err, "Failed to index episodes");
                            }
                        }
                    }
                    out
                }
                Err(err) => {
                    warn!(section = %section.key, %err, "Failed to index Plex show section");
                    Vec::new()
                }
            },
            _ => Vec::new(),
        }
    }
}

#[async_trait]
impl WatchedSyncAdapter for PlexWatchedSync {
    async fn fetch_watched(
        &self,
        config: &MediaServerConfig,
    ) -> Result<Vec<WatchedItem>, IntegrationError> {
        let sections = self.client.list_sections(config).await?;
        let mut out = Vec::new();
        for section in &sections {
            out.extend(self.fetch_section(config, section).await);
        }
        Ok(out)
    }

    async fn mark_watched(
        &self,
        config: &MediaServerConfig,
        server_item_id: &str,
    ) -> Result<(), IntegrationError> {
        self.client.scrobble(config, server_item_id).await
    }

    async fn mark_unwatched(
        &self,
        config: &MediaServerConfig,
        server_item_id: &str,
    ) -> Result<(), IntegrationError> {
        self.client.unscrobble(config, server_item_id).await
    }

    async fn build_server_index(
        &self,
        config: &MediaServerConfig,
    ) -> Result<BTreeMap<String, String>, IntegrationError> {
        let sections = self.client.list_sections(config).await?;
        let mut out = BTreeMap::new();
        for section in &sections {
            for (k, v) in self.index_section(config, section).await {
                out.insert(k, v);
            }
        }
        Ok(out)
    }
}

fn format_episode_title(show_title: &str, ep: &PlexEpisode) -> String {
    let season = ep.season_number.unwrap_or(0);
    let episode = ep.episode_number.unwrap_or(0);
    format!("{show_title} S{season}E{episode}")
}

fn format_episode_suffix(ep: &PlexEpisode) -> String {
    let season = ep.season_number.unwrap_or(0);
    let episode = ep.episode_number.unwrap_or(0);
    format!("s{season}e{episode}")
}

fn build_index_entries(
    kind: &str,
    guids: &BTreeMap<String, String>,
    rating_key: &str,
) -> Vec<(String, String)> {
    guids
        .iter()
        .map(|(provider, id)| (format!("{kind}:{provider}:{id}"), rating_key.to_owned()))
        .collect()
}

/// Stats returned by the orchestrator. Mirrors the Phoenix
/// `%{imported, skipped, not_found, exported, export_skipped}` map.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SyncStats {
    pub imported: u32,
    pub skipped: u32,
    pub not_found: u32,
    pub exported: u32,
    pub export_skipped: u32,
}

impl SyncStats {
    pub fn merge(self, other: &Self) -> Self {
        Self {
            imported: self.imported + other.imported,
            skipped: self.skipped + other.skipped,
            not_found: self.not_found + other.not_found,
            exported: self.exported + other.exported,
            export_skipped: self.export_skipped + other.export_skipped,
        }
    }
}

/// Build the lookup key for a movie / show in the server index.
///
/// Mirrors `lib/mydia/media_server/watched_sync/orchestrator.ex`'s
/// `find_in_server_index/4` helper. The Phoenix version iterates
/// over `imdb`, `tvdb`, `tmdb`; we keep that order so cross-version
/// reads agree.
#[must_use]
pub fn lookup_movie_key(
    server_index: &BTreeMap<String, String>,
    imdb: Option<&str>,
    tvdb: Option<&str>,
    tmdb: Option<&str>,
) -> Option<String> {
    for (provider, id) in [("imdb", imdb), ("tvdb", tvdb), ("tmdb", tmdb)] {
        if let Some(id) = id {
            let key = format!("movie:{provider}:{id}");
            if let Some(rating_key) = server_index.get(&key) {
                return Some(rating_key.clone());
            }
        }
    }
    None
}

/// Build the lookup key for an episode in the server index. Suffix is
/// `s{season}e{episode}`.
#[must_use]
pub fn lookup_episode_key(
    server_index: &BTreeMap<String, String>,
    imdb: Option<&str>,
    tvdb: Option<&str>,
    tmdb: Option<&str>,
    season_number: i32,
    episode_number: i32,
) -> Option<String> {
    let suffix = format!("s{season_number}e{episode_number}");
    for (provider, id) in [("imdb", imdb), ("tvdb", tvdb), ("tmdb", tmdb)] {
        if let Some(id) = id {
            let key = format!("episode:{provider}:{id}:{suffix}");
            if let Some(rating_key) = server_index.get(&key) {
                return Some(rating_key.clone());
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn server_index() -> BTreeMap<String, String> {
        let mut map = BTreeMap::new();
        map.insert("movie:tmdb:27205".into(), "rk-1".into());
        map.insert("movie:imdb:tt1234567".into(), "rk-2".into());
        map.insert("episode:tvdb:9999:s1e3".into(), "rk-3".into());
        map
    }

    #[test]
    fn movie_lookup_iterates_imdb_first() {
        let idx = server_index();
        let key = lookup_movie_key(&idx, Some("tt1234567"), None, Some("27205")).unwrap();
        // Phoenix iterates imdb → tvdb → tmdb; imdb wins.
        assert_eq!(key, "rk-2");
    }

    #[test]
    fn movie_lookup_falls_through_to_tmdb() {
        let idx = server_index();
        let key = lookup_movie_key(&idx, None, None, Some("27205")).unwrap();
        assert_eq!(key, "rk-1");
    }

    #[test]
    fn movie_lookup_none_when_no_match() {
        let idx = server_index();
        assert!(lookup_movie_key(&idx, Some("tt999999"), None, None).is_none());
    }

    #[test]
    fn episode_lookup_uses_suffix() {
        let idx = server_index();
        let key = lookup_episode_key(&idx, None, Some("9999"), None, 1, 3).unwrap();
        assert_eq!(key, "rk-3");
        assert!(lookup_episode_key(&idx, None, Some("9999"), None, 2, 1).is_none());
    }

    #[test]
    fn sync_stats_merge_sums_fields() {
        let a = SyncStats {
            imported: 1,
            skipped: 2,
            ..Default::default()
        };
        let b = SyncStats {
            exported: 3,
            export_skipped: 4,
            ..Default::default()
        };
        let merged = a.merge(&b);
        assert_eq!(merged.imported, 1);
        assert_eq!(merged.skipped, 2);
        assert_eq!(merged.exported, 3);
        assert_eq!(merged.export_skipped, 4);
    }
}
