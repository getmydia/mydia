//! Instance store keys (the shared table in the plan skeleton, plus `server/*`).

use crate::host::Host;
use crate::http::PlexError;
use serde::de::DeserializeOwned;
use serde::Serialize;

pub const ENDPOINT_CURRENT: &str = "endpoint/current";
/// `endpoint::ServerInfo` of the chosen server.
pub const SERVER_INFO: &str = "server/info";
/// `endpoint::ServerInfo` from a rediscovery whose addresses need operator approval.
pub const SERVER_PENDING: &str = "server/pending";
/// plex.tv uuid of the account that ran setup.
pub const SERVER_OWNER_ACCOUNT: &str = "server/owner_account_id";
/// `"1"` when the account has Plex Home, `"0"` when not.
pub const SERVER_HOME: &str = "server/home";
pub const CRAWL_STATE: &str = "crawl/state";

pub fn map_key(rating_key: &str) -> String {
    format!("map/{rating_key}")
}

pub fn rev_movie_key(source: &str, id: &str) -> String {
    format!("rev/movie/{source}/{id}")
}

pub fn rev_episode_key(source: &str, show_id: &str, season: u32, episode: u32) -> String {
    format!("rev/episode/{source}/{show_id}/{season}/{episode}")
}

pub fn link_state_key(link_id: &str, item_key: &str) -> String {
    format!("link/{link_id}/state/{item_key}")
}

pub fn link_pull_cursor_key(link_id: &str) -> String {
    format!("link/{link_id}/cursor/pull")
}

/// RFC3339 `updated-at` of the last local row the push pass processed for a link.
pub fn link_push_cursor_key(link_id: &str) -> String {
    format!("link/{link_id}/cursor/push")
}

/// An unfinished pull pass for a link, so a large first pull spans ticks.
pub fn link_pull_page_key(link_id: &str) -> String {
    format!("link/{link_id}/cursor/pull_page")
}

/// Present (`"1"`) on a user link that syncs through the owner link because the
/// account has no Plex Home to mint a per-profile token from.
pub fn link_uses_owner_key(link_id: &str) -> String {
    format!("link/{link_id}/uses_owner")
}

fn host_err(e: mydia_plugin_sdk::types::HostError) -> PlexError {
    PlexError::Unexpected(format!("store: {e:?}"))
}

/// A value that fails to parse reads as absent: working state is a cache, and a
/// corrupt entry must cost a re-crawl, not a stuck plugin.
pub fn get_json<T: DeserializeOwned>(
    host: &mut dyn Host,
    key: &str,
) -> Result<Option<T>, PlexError> {
    Ok(host
        .kv_get(key)
        .map_err(host_err)?
        .and_then(|raw| serde_json::from_str(&raw).ok()))
}

pub fn put_json<T: Serialize>(host: &mut dyn Host, key: &str, value: &T) -> Result<(), PlexError> {
    let raw = serde_json::to_string(value).map_err(|e| PlexError::Unexpected(e.to_string()))?;
    host.kv_set(key, &raw).map_err(host_err)
}

/// The host refuses a `kv-set-many` over this many entries (`Kv.max_batch`).
pub const KV_MAX_BATCH: usize = 500;

/// Writes `entries` in order, in batches the host accepts. Each batch is atomic
/// on the host, so an entry that must not land before the others (a resume
/// cursor) goes last: it then sits in the final batch, and a failure part way
/// leaves the cursor behind the data it describes.
pub fn set_many(
    host: &mut dyn Host,
    entries: &[mydia_plugin_sdk::types::KvEntry],
) -> Result<(), mydia_plugin_sdk::types::HostError> {
    for chunk in entries.chunks(KV_MAX_BATCH) {
        host.kv_set_many(chunk)?;
    }
    Ok(())
}

pub fn delete(host: &mut dyn Host, key: &str) -> Result<(), PlexError> {
    host.kv_delete(key).map_err(host_err)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::host::fake::FakeHost;

    #[test]
    fn per_link_cursor_keys() {
        assert_eq!(link_push_cursor_key("l1"), "link/l1/cursor/push");
        assert_eq!(link_pull_page_key("l1"), "link/l1/cursor/pull_page");
    }

    #[test]
    fn key_shapes_match_the_shared_table() {
        assert_eq!(map_key("42"), "map/42");
        assert_eq!(rev_movie_key("tmdb", "603"), "rev/movie/tmdb/603");
        assert_eq!(
            rev_episode_key("tvdb", "81189", 1, 2),
            "rev/episode/tvdb/81189/1/2"
        );
        assert_eq!(link_state_key("l1", "77"), "link/l1/state/77");
        assert_eq!(link_pull_cursor_key("l1"), "link/l1/cursor/pull");
        assert_eq!(link_uses_owner_key("l1"), "link/l1/uses_owner");
    }

    #[test]
    fn json_round_trips_and_missing_is_none() {
        let mut host = FakeHost::new();
        put_json(&mut host, "k", &vec![1, 2]).unwrap();
        let back: Option<Vec<i32>> = get_json(&mut host, "k").unwrap();
        assert_eq!(back, Some(vec![1, 2]));
        let none: Option<Vec<i32>> = get_json(&mut host, "missing").unwrap();
        assert_eq!(none, None);
    }

    #[test]
    fn set_many_chunks_to_the_host_batch_limit_and_keeps_order() {
        use mydia_plugin_sdk::types::KvEntry;
        let mut host = FakeHost::new();
        let entries: Vec<KvEntry> = (0..1201)
            .map(|i| KvEntry {
                key: format!("k/{i:05}"),
                value: "v".into(),
            })
            .collect();
        set_many(&mut host, &entries).unwrap();
        let sizes: Vec<usize> = host.batches.iter().map(Vec::len).collect();
        assert_eq!(sizes, vec![500, 500, 201]);
        assert_eq!(host.batches[2].last().unwrap(), "k/01200");
        assert_eq!(host.kv.len(), 1201);
    }

    #[test]
    fn a_corrupt_value_reads_as_none() {
        let mut host = FakeHost::new();
        host.kv.insert("k".into(), "{not json".into());
        let v: Option<Vec<i32>> = get_json(&mut host, "k").unwrap();
        assert_eq!(v, None);
    }
}
