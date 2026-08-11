//! Simkl two-way watched-state sync plugin (U9).
//!
//! Proves the 1.1 platform surfaces end to end: per-user connections (the host
//! attaches the bearer token via `connection-request` — the guest never sees a
//! token), KV state for watermarks/cursors/checkpoints, scheduled invocation,
//! list reads, and watched write-back.
//!
//! All per-connection state is keyed under the host-sweepable `conn/<id>/`
//! prefix (R20), so reconnecting a different account starts fresh and a removed
//! connection's state is swept with it.
//!
//! Invariants:
//!   * Pull (R15): each chunk's pulled-set delta is checkpointed to KV *before*
//!     `ensure-watched` is applied, so a kill mid-pull resumes idempotently
//!     without losing the echo guard.
//!   * Push (R16): the pending batch is persisted to KV before POST and cleared
//!     after, so a kill between POST and clear re-sends (a duplicate Simkl
//!     history entry is benign; a lost watch is not). Items pulled this run are
//!     excluded from the push by the pulled-set (no echo).

use mydia_plugin_sdk::host;
use mydia_plugin_sdk::types::{
    Connection, ConnectionStatus, Event, LibraryItem, ListItem, ListRequest, OutboundRequest,
    PlaybackProgress, ScheduleTick, WatchTarget,
};
use std::collections::{BTreeSet, HashMap};
use tinyjson::JsonValue;

const DEFAULT_API_BASE: &str = "https://api.simkl.com";

// ── Handlers ────────────────────────────────────────────────────────────────

#[mydia_plugin_sdk::plugin(on_schedule = on_schedule)]
fn on_event(evt: Event) -> Result<String, String> {
    // React only to player-origin finishes. The dispatcher already suppresses
    // our own write-back echoes; skipping non-player origins keeps a sync:* or
    // foreign-plugin write from triggering an immediate re-push loop.
    if evt.event == "playback.finished" && origin_of(&evt).as_deref() == Some("player") {
        if let Some(user_id) = evt.actor_id.clone() {
            let api_base = api_base_from(&config_json_of(&evt));
            if let Some(conn) = connection_for_user(&user_id) {
                let pulled = BTreeSet::new();
                let _ = push(&conn, &api_base, &pulled);
            }
        }
    }

    Ok("{}".to_string())
}

fn on_schedule(tick: ScheduleTick) -> Result<String, String> {
    let api_base = api_base_from(&tick.config_json);

    let conns = match host::connections_list() {
        Ok(c) => c,
        Err(e) => return Err(format!("connections-list failed: {:?}", e)),
    };

    let mut invalid: Vec<String> = Vec::new();
    let mut pulled_total = 0usize;
    let mut pushed_total = 0usize;
    let mut unmatched = 0usize;

    for conn in conns {
        if matches!(conn.status, ConnectionStatus::Error) {
            continue;
        }

        match sync_connection(&conn, &api_base) {
            Ok(counts) => {
                host::log(
                    "info",
                    &format!(
                        "simkl[{}]: pulled={} pushed={} unmatched={}",
                        conn.user_id, counts.pulled, counts.pushed, counts.unmatched
                    ),
                );
                pulled_total += counts.pulled;
                pushed_total += counts.pushed;
                unmatched += counts.unmatched;
            }
            // A 401 invalidates just this connection; other users still sync.
            Err(SyncError::Unauthorized) => {
                host::log(
                    "warn",
                    &format!("simkl[{}]: connection unauthorized (401)", conn.user_id),
                );
                invalid.push(conn.user_id.clone());
            }
            Err(SyncError::Host(msg)) => host::log("warn", &format!("simkl sync error: {msg}")),
        }
    }

    if unmatched > 0 {
        host::log(
            "info",
            &format!("simkl: {unmatched} item(s) had no local match"),
        );
    }

    Ok(result_json(pushed_total, pulled_total, &invalid))
}

// ── Sync engine ─────────────────────────────────────────────────────────────

struct Counts {
    pulled: usize,
    pushed: usize,
    unmatched: usize,
}

enum SyncError {
    Unauthorized,
    Host(String),
}

fn sync_connection(conn: &Connection, api_base: &str) -> Result<Counts, SyncError> {
    let (pulled_keys, pulled, unmatched) = pull(conn, api_base)?;
    let pushed = push(conn, api_base, &pulled_keys)?;
    Ok(Counts {
        pulled,
        pushed,
        unmatched,
    })
}

// Pull leg — gated by the activities cursor. Returns the pulled-set (for the
// push echo guard), how many items were applied, and how many had no local
// match.
fn pull(conn: &Connection, api_base: &str) -> Result<(BTreeSet<String>, usize, usize), SyncError> {
    let cursor_key = key(conn, "activities");
    let stored = kv_get(&cursor_key);

    let activities_body = simkl_get(conn, &format!("{api_base}/sync/activities"))?;
    let activities = parse_activities(&activities_body);

    if activities.is_none() {
        host::log(
            "warn",
            "simkl: /sync/activities had no top-level 'all' cursor; pull will not advance",
        );
    }

    // Unchanged cursor → skip the pull leg only (push still runs).
    if activities.is_some() && stored == activities {
        host::log(
            "debug",
            "simkl: activities cursor unchanged, skipping pull leg",
        );
        return Ok((load_pulled_set(conn), 0, 0));
    }

    let date_from = stored.clone().unwrap_or_default();
    // `episode_watched_at=yes&extended=full` makes shows/anime entries carry
    // `seasons[].episodes[].watched_at` (KTD2); without them Simkl returns only a
    // show-level summary that cannot produce per-episode coordinates. `date_from`
    // keeps the pull incremental (R-PULL-3).
    let items_body = simkl_get(
        conn,
        &format!(
            "{api_base}/sync/all-items?date_from={date_from}&episode_watched_at=yes&extended=full"
        ),
    )?;
    let items = parse_all_items(&items_body);
    // The direct diagnostic for the "pulled 0 against a full account" failure:
    // a non-trivial body that parses to nothing means a response-shape mismatch.
    host::log(
        "debug",
        &format!(
            "simkl: all-items parsed {} watched item(s) from {} bytes",
            items.len(),
            items_body.len()
        ),
    );

    let mut pulled_keys = load_pulled_set(conn);
    let mut applied = 0usize;
    let mut unmatched = 0usize;

    for item in &items {
        // R15: persist the pulled-set delta BEFORE applying ensure-watched, so a
        // kill after the checkpoint keeps the item out of the push even though
        // the local write has not happened yet (the next run re-applies it
        // idempotently).
        pulled_keys.insert(item.key());
        save_pulled_set(conn, &pulled_keys);

        match host::ensure_watched(&item.to_target(conn)) {
            Ok(_) => applied += 1,
            Err(_) => unmatched += 1,
        }
    }

    // Advance the pull watermark to the Simkl activities timestamp only after the
    // whole page applied.
    if let Some(ts) = activities {
        let _ = host::kv_set(&cursor_key, &ts);
    }

    Ok((pulled_keys, applied, unmatched))
}

// Push leg — always runs, gated only by the push watermark (R16). Items in the
// pulled-set are excluded so a just-pulled watch is never echoed back.
fn push(
    conn: &Connection,
    api_base: &str,
    pulled_keys: &BTreeSet<String>,
) -> Result<usize, SyncError> {
    let watermark_key = key(conn, "push");
    let pending_key = key(conn, "pending");

    // At-least-once: a pending batch from a prior interrupted run is re-sent
    // first (a duplicate history entry is benign; a lost watch is not).
    if let Some(pending) = kv_get(&pending_key) {
        simkl_post(conn, &format!("{api_base}/sync/history"), &pending)?;
        let _ = host::kv_delete(&pending_key);
    }

    let watermark = kv_get(&watermark_key);
    let rows = list_progress(conn, watermark.as_deref());

    let to_push: Vec<PushItem> = rows
        .iter()
        .filter(|r| r.watched && r.user_id == conn.user_id)
        .filter_map(PushItem::from_progress)
        .filter(|p| !pulled_keys.contains(&p.key))
        .collect();

    if to_push.is_empty() {
        // Nothing to push, but still prune the pulled-set so it does not grow.
        clear_pulled_set(conn);
        return Ok(0);
    }

    // Simkl caps a history write at 50 items.
    let mut total = 0usize;
    for batch in to_push.chunks(50) {
        let body = build_history_body(batch);
        // Persist before POST so a kill in-flight re-sends next run.
        let _ = host::kv_set(&pending_key, &body);
        simkl_post(conn, &format!("{api_base}/sync/history"), &body)?;
        let _ = host::kv_delete(&pending_key);
        total += batch.len();
    }

    // Advance the watermark past the items we just pushed, then prune the
    // pulled-set (those items are now behind the watermark).
    if let Some(max_ts) = to_push.iter().map(|p| p.updated_at.clone()).max() {
        let _ = host::kv_set(&watermark_key, &max_ts);
    }
    clear_pulled_set(conn);

    Ok(total)
}

// ── Simkl HTTP (host-attached auth) ──────────────────────────────────────────

fn simkl_get(conn: &Connection, url: &str) -> Result<String, SyncError> {
    let req = OutboundRequest {
        url: url.to_string(),
        method: "GET".to_string(),
        headers: vec![("accept".to_string(), "application/json".to_string())],
        body: None,
    };
    send(conn, &req)
}

fn simkl_post(conn: &Connection, url: &str, body: &str) -> Result<String, SyncError> {
    let req = OutboundRequest {
        url: url.to_string(),
        method: "POST".to_string(),
        headers: vec![("content-type".to_string(), "application/json".to_string())],
        body: Some(body.to_string()),
    };
    send(conn, &req)
}

fn send(conn: &Connection, req: &OutboundRequest) -> Result<String, SyncError> {
    match host::connection_request(&conn.id, req) {
        Ok(resp) if resp.status == 401 => Err(SyncError::Unauthorized),
        Ok(resp) => Ok(resp.body.unwrap_or_default()),
        Err(e) => Err(SyncError::Host(format!("{:?}", e))),
    }
}

// ── KV helpers ────────────────────────────────────────────────────────────────

fn key(conn: &Connection, name: &str) -> String {
    format!("conn/{}/{}", conn.id, name)
}

fn kv_get(k: &str) -> Option<String> {
    host::kv_get(k).ok().flatten()
}

fn load_pulled_set(conn: &Connection) -> BTreeSet<String> {
    match kv_get(&key(conn, "pulled")) {
        Some(raw) => parse_string_array(&raw).into_iter().collect(),
        None => BTreeSet::new(),
    }
}

fn save_pulled_set(conn: &Connection, set: &BTreeSet<String>) {
    let _ = host::kv_set(&key(conn, "pulled"), &string_array_json(set));
}

fn clear_pulled_set(conn: &Connection) {
    let _ = host::kv_delete(&key(conn, "pulled"));
}

// ── data-list (paginated) ─────────────────────────────────────────────────────

fn list_progress(conn: &Connection, updated_since: Option<&str>) -> Vec<PlaybackProgress> {
    let mut out = Vec::new();
    let mut cursor: Option<String> = None;

    loop {
        let req = ListRequest {
            namespace: "playback_progress".to_string(),
            cursor: cursor.clone(),
            updated_since: updated_since.map(|s| s.to_string()),
            limit: Some(200),
        };

        let result = match host::data_list(&req) {
            Ok(r) => r,
            Err(_) => break,
        };

        for item in result.items {
            if let ListItem::PlaybackProgress(p) = item {
                out.push(p);
            }
        }

        match result.next_cursor {
            Some(c) => cursor = Some(c),
            None => break,
        }
    }

    let _ = conn;
    out
}

// ── Pure helpers (unit-tested) ────────────────────────────────────────────────

/// A watched item pulled from Simkl.
struct PulledItem {
    imdb: Option<String>,
    tmdb: Option<i64>,
    tvdb: Option<i64>,
    season: Option<u32>,
    episode: Option<u32>,
    watched_at: Option<String>,
}

impl PulledItem {
    /// A stable dedupe key for the echo guard.
    fn key(&self) -> String {
        item_key(
            self.imdb.as_deref(),
            self.tmdb,
            self.tvdb,
            self.season,
            self.episode,
        )
    }

    fn to_target(&self, conn: &Connection) -> WatchTarget {
        WatchTarget {
            user_id: conn.user_id.clone(),
            imdb_id: self.imdb.clone(),
            tmdb_id: self.tmdb,
            tvdb_id: self.tvdb,
            season_number: self.season,
            episode_number: self.episode,
            watched_at: self.watched_at.clone(),
        }
    }
}

/// A local watch to push to Simkl.
struct PushItem {
    imdb: Option<String>,
    tmdb: Option<i64>,
    tvdb: Option<i64>,
    season: Option<u32>,
    episode: Option<u32>,
    updated_at: String,
    key: String,
}

impl PushItem {
    fn from_progress(p: &PlaybackProgress) -> Option<PushItem> {
        let (season, episode) = if p.item_type == "episode" {
            (p.season_number, p.episode_number)
        } else {
            (None, None)
        };

        let key = item_key(p.imdb_id.as_deref(), p.tmdb_id, p.tvdb_id, season, episode);

        Some(PushItem {
            imdb: p.imdb_id.clone(),
            tmdb: p.tmdb_id,
            tvdb: p.tvdb_id,
            season,
            episode,
            updated_at: p.updated_at.clone(),
            key,
        })
    }
}

/// A stable key over external ids + episode coordinates. Used both as the
/// pulled-set membership key and the push dedupe key, so the two sides line up.
fn item_key(
    imdb: Option<&str>,
    tmdb: Option<i64>,
    tvdb: Option<i64>,
    season: Option<u32>,
    episode: Option<u32>,
) -> String {
    let id = if let Some(i) = imdb {
        format!("imdb:{i}")
    } else if let Some(t) = tmdb {
        format!("tmdb:{t}")
    } else if let Some(t) = tvdb {
        format!("tvdb:{t}")
    } else {
        "unknown".to_string()
    };

    match (season, episode) {
        (Some(s), Some(e)) => format!("{id}:s{s}e{e}"),
        _ => id,
    }
}

/// One entry on a Simkl list, or one local item destined for one. Movies and
/// shows go into different arrays in every Simkl body, so the split is carried
/// on the entry rather than recomputed at each call site.
#[cfg_attr(not(test), allow(dead_code))]
struct ListEntry {
    imdb: Option<String>,
    tmdb: Option<i64>,
    tvdb: Option<i64>,
    is_show: bool,
    key: String,
}

/// An item-level key: the same shape `item_key` produces with no episode
/// coordinates. Favorites and list membership address a show as a whole, so a
/// single watched episode must collapse onto the show's key.
#[cfg_attr(not(test), allow(dead_code))]
fn intent_key(imdb: Option<&str>, tmdb: Option<i64>, tvdb: Option<i64>) -> String {
    item_key(imdb, tmdb, tvdb, None, None)
}

/// The local intent set D: owned, and with no watch progress for this user.
///
/// Progress rows are keyed item-level on purpose. An episode row carries its
/// *show's* external ids (the host's `progress_dimensions`), so one watched
/// episode drops the whole show out of D, which is correct: Simkl already
/// files a partly watched show under "watching" from the history leg.
#[cfg_attr(not(test), allow(dead_code))]
fn local_intent_set(
    library: &[LibraryItem],
    progress: &[PlaybackProgress],
    user_id: &str,
) -> BTreeSet<String> {
    let touched: BTreeSet<String> = progress
        .iter()
        .filter(|p| p.user_id == user_id)
        .map(|p| intent_key(p.imdb_id.as_deref(), p.tmdb_id, p.tvdb_id))
        .collect();

    library
        .iter()
        .filter(|l| l.owned)
        .map(|l| intent_key(l.imdb_id.as_deref(), l.tmdb_id, l.tvdb_id))
        // `k` is a `&String` here, so compare and look up through `as_str()`:
        // `&String == &str` is not implemented.
        .filter(|k| k.as_str() != "unknown" && !touched.contains(k.as_str()))
        .collect()
}

/// Parses a `/sync/all-items/{type}/plantowatch?extended=simkl_ids_only` body.
///
/// Same nesting as the full shape the history leg parses: ids live under a
/// `show`/`movie` sub-object, and `tvdb`/`tmdb` arrive as strings here but as
/// numbers elsewhere, so `coerce_i64` stays bidirectional. A structural
/// mismatch yields an empty list rather than an error, matching
/// `parse_all_items`.
#[cfg_attr(not(test), allow(dead_code))]
fn parse_mini_list(body: &str, is_show: bool) -> Vec<ListEntry> {
    let json: JsonValue = match body.parse() {
        Ok(j) => j,
        Err(_) => return Vec::new(),
    };
    let obj = match json.get::<HashMap<String, JsonValue>>() {
        Some(o) => o,
        None => return Vec::new(),
    };

    let (array_key, sub_key) = if is_show {
        ("shows", "show")
    } else {
        ("movies", "movie")
    };

    let Some(JsonValue::Array(entries)) = obj.get(array_key) else {
        return Vec::new();
    };

    entries
        .iter()
        .filter_map(|entry| {
            let entry_obj = entry.get::<HashMap<String, JsonValue>>()?;
            let ids = sub_ids(entry_obj, sub_key)?;
            let (imdb, tmdb, tvdb) = extract_ids(ids);
            let key = intent_key(imdb.as_deref(), tmdb, tvdb);

            if key == "unknown" {
                return None;
            }

            Some(ListEntry {
                imdb,
                tmdb,
                tvdb,
                is_show,
                key,
            })
        })
        .collect()
}

/// Builds a `/sync/add-to-list` body, splitting movies and shows and marking
/// every entry `plantowatch`.
#[cfg_attr(not(test), allow(dead_code))]
fn build_add_to_list_body(items: &[ListEntry]) -> String {
    let mut movies: Vec<String> = Vec::new();
    let mut shows: Vec<String> = Vec::new();

    for item in items {
        let entry = format!(
            "{{\"to\":\"plantowatch\",\"ids\":{}}}",
            ids_json(item.imdb.as_deref(), item.tmdb, item.tvdb)
        );

        if item.is_show {
            shows.push(entry);
        } else {
            movies.push(entry);
        }
    }

    format!(
        "{{\"movies\":[{}],\"shows\":[{}]}}",
        movies.join(","),
        shows.join(",")
    )
}

/// Builds the Simkl `/sync/history` POST body from a batch of push items,
/// splitting movies and episodes (each episode carries its show's ids plus
/// coordinates).
fn build_history_body(items: &[PushItem]) -> String {
    let mut movies = Vec::new();
    let mut episodes = Vec::new();

    for it in items {
        match (it.season, it.episode) {
            (Some(s), Some(e)) => {
                episodes.push(format!(
                    "{{\"ids\":{},\"season\":{},\"episode\":{}}}",
                    ids_json(it.imdb.as_deref(), it.tmdb, it.tvdb),
                    s,
                    e
                ));
            }
            _ => {
                movies.push(format!(
                    "{{\"ids\":{}}}",
                    ids_json(it.imdb.as_deref(), it.tmdb, it.tvdb)
                ));
            }
        }
    }

    format!(
        "{{\"movies\":[{}],\"episodes\":[{}]}}",
        movies.join(","),
        episodes.join(",")
    )
}

fn ids_json(imdb: Option<&str>, tmdb: Option<i64>, tvdb: Option<i64>) -> String {
    let mut parts = Vec::new();
    if let Some(i) = imdb {
        parts.push(format!("\"imdb\":{:?}", i));
    }
    if let Some(t) = tmdb {
        parts.push(format!("\"tmdb\":{t}"));
    }
    if let Some(t) = tvdb {
        parts.push(format!("\"tvdb\":{t}"));
    }
    format!("{{{}}}", parts.join(","))
}

/// Parses `/sync/activities` to the single `all` timestamp used as the cursor.
fn parse_activities(body: &str) -> Option<String> {
    let json: JsonValue = body.parse().ok()?;
    let obj = json.get::<std::collections::HashMap<String, JsonValue>>()?;
    obj.get("all").and_then(|v| v.get::<String>()).cloned()
}

/// Parses Simkl's real `/sync/all-items?episode_watched_at=yes&extended=full`
/// response into pulled items. The body has three top-level arrays — `shows`,
/// `anime`, and `movies` (there is no flat `episodes` key) — with external ids
/// nested under a `show`/`movie` sub-object and `tvdb`/`tmdb` encoded as strings:
///
/// ```text
/// {
///   "shows": [{ "status": "watching",
///               "show": { "ids": { "tvdb": "320724", "tmdb": "67195" } },
///               "seasons": [{ "number": 1,
///                             "episodes": [{ "number": 1, "watched_at": "..." }] }] }],
///   "anime": [ ...same shape as shows... ],
///   "movies": [{ "status": "completed", "last_watched_at": "...",
///                "movie": { "ids": { "imdb": "tt.." } } }]
/// }
/// ```
///
/// Shows/anime emit one `PulledItem` per episode that carries a `watched_at`
/// (KTD4); movies emit one per `completed`/`last_watched_at` entry. A structural
/// mismatch yields an empty list rather than erroring (see the plan's deferred
/// hardening note).
fn parse_all_items(body: &str) -> Vec<PulledItem> {
    let mut out = Vec::new();

    let json: JsonValue = match body.parse() {
        Ok(j) => j,
        Err(_) => return out,
    };
    let obj = match json.get::<HashMap<String, JsonValue>>() {
        Some(o) => o,
        None => return out,
    };

    // Shows and anime share the same nested `show`/`seasons` shape.
    for key in ["shows", "anime"] {
        if let Some(JsonValue::Array(entries)) = obj.get(key) {
            for entry in entries {
                parse_show_entry(entry, &mut out);
            }
        }
    }

    if let Some(JsonValue::Array(movies)) = obj.get("movies") {
        for entry in movies {
            if let Some(item) = parse_movie_entry(entry) {
                out.push(item);
            }
        }
    }

    out
}

/// A show/anime entry: ids live under `show.ids`; each `seasons[].episodes[]`
/// with a `watched_at` becomes one `PulledItem` carrying the show ids plus the
/// season/episode coordinates (KTD4). Entries without watched episodes (or no
/// `seasons`, e.g. when the extended params were not honored) contribute nothing.
fn parse_show_entry(value: &JsonValue, out: &mut Vec<PulledItem>) {
    let Some(obj) = value.get::<HashMap<String, JsonValue>>() else {
        return;
    };
    let Some(ids) = sub_ids(obj, "show") else {
        return;
    };
    let (imdb, tmdb, tvdb) = extract_ids(ids);

    let Some(JsonValue::Array(seasons)) = obj.get("seasons") else {
        return;
    };

    for season in seasons {
        let Some(season_obj) = season.get::<HashMap<String, JsonValue>>() else {
            continue;
        };
        let season_num = season_obj.get("number").and_then(coerce_u32);

        let Some(JsonValue::Array(episodes)) = season_obj.get("episodes") else {
            continue;
        };

        for ep in episodes {
            let Some(ep_obj) = ep.get::<HashMap<String, JsonValue>>() else {
                continue;
            };
            // Gate on per-episode `watched_at`: a "watching" show still carries
            // watched episodes, and only those should pull (KTD4).
            let Some(watched_at) = ep_obj
                .get("watched_at")
                .and_then(|v| v.get::<String>())
                .cloned()
            else {
                continue;
            };
            let episode_num = ep_obj.get("number").and_then(coerce_u32);

            out.push(PulledItem {
                imdb: imdb.clone(),
                tmdb,
                tvdb,
                season: season_num,
                episode: episode_num,
                watched_at: Some(watched_at),
            });
        }
    }
}

/// A movie entry: ids live under `movie.ids`; a `completed` status or a present
/// `last_watched_at` marks it watched (KTD4).
fn parse_movie_entry(value: &JsonValue) -> Option<PulledItem> {
    let obj = value.get::<HashMap<String, JsonValue>>()?;
    let ids = sub_ids(obj, "movie")?;
    let (imdb, tmdb, tvdb) = extract_ids(ids);

    let completed = obj
        .get("status")
        .and_then(|v| v.get::<String>())
        .map(|s| s == "completed")
        .unwrap_or(false);
    let watched_at = obj
        .get("last_watched_at")
        .and_then(|v| v.get::<String>())
        .cloned();

    if !completed && watched_at.is_none() {
        return None;
    }

    Some(PulledItem {
        imdb,
        tmdb,
        tvdb,
        season: None,
        episode: None,
        watched_at,
    })
}

/// Reads `entry[sub]["ids"]` as an object — the nested `show.ids` / `movie.ids`
/// location Simkl uses on `/sync/all-items` (KTD1).
fn sub_ids<'a>(
    obj: &'a HashMap<String, JsonValue>,
    sub: &str,
) -> Option<&'a HashMap<String, JsonValue>> {
    obj.get(sub)?
        .get::<HashMap<String, JsonValue>>()?
        .get("ids")?
        .get::<HashMap<String, JsonValue>>()
}

/// Extracts the three external ids from an `ids` object, coercing `tvdb`/`tmdb`
/// from either string or number form (KTD3).
fn extract_ids(ids: &HashMap<String, JsonValue>) -> (Option<String>, Option<i64>, Option<i64>) {
    let imdb = ids.get("imdb").and_then(|v| v.get::<String>()).cloned();
    let tmdb = ids.get("tmdb").and_then(coerce_i64);
    let tvdb = ids.get("tvdb").and_then(coerce_i64);
    (imdb, tmdb, tvdb)
}

/// Accepts a JSON value that is either a number or a numeric string and yields
/// `i64`. Simkl returns `tvdb`/`tmdb` as strings on `/sync/all-items` but as
/// numbers elsewhere; the coercion stays bidirectional so a future shape flip
/// does not reintroduce the bug (KTD3).
fn coerce_i64(v: &JsonValue) -> Option<i64> {
    match v {
        JsonValue::Number(n) => Some(*n as i64),
        JsonValue::String(s) => s.trim().parse::<i64>().ok(),
        _ => None,
    }
}

fn coerce_u32(v: &JsonValue) -> Option<u32> {
    coerce_i64(v).and_then(|n| u32::try_from(n).ok())
}

fn parse_string_array(body: &str) -> Vec<String> {
    match body.parse::<JsonValue>() {
        Ok(JsonValue::Array(arr)) => arr
            .iter()
            .filter_map(|v| v.get::<String>().cloned())
            .collect(),
        _ => Vec::new(),
    }
}

fn string_array_json(set: &BTreeSet<String>) -> String {
    let parts: Vec<String> = set.iter().map(|s| format!("{:?}", s)).collect();
    format!("[{}]", parts.join(","))
}

fn result_json(pushed: usize, pulled: usize, invalid: &[String]) -> String {
    let ids: Vec<String> = invalid.iter().map(|s| format!("{:?}", s)).collect();
    format!(
        "{{\"pushed\":{pushed},\"pulled\":{pulled},\"connections_invalid\":[{}]}}",
        ids.join(",")
    )
}

fn connection_for_user(user_id: &str) -> Option<Connection> {
    host::connections_list()
        .ok()?
        .into_iter()
        .find(|c| c.user_id == user_id && matches!(c.status, ConnectionStatus::Connected))
}

fn origin_of(evt: &Event) -> Option<String> {
    let json: JsonValue = evt.metadata_json.parse().ok()?;
    let obj = json.get::<std::collections::HashMap<String, JsonValue>>()?;
    obj.get("origin").and_then(|v| v.get::<String>()).cloned()
}

fn config_json_of(evt: &Event) -> String {
    // The host injects "config" into the event metadata bag on every path.
    if let Ok(JsonValue::Object(obj)) = evt.metadata_json.parse::<JsonValue>() {
        if let Some(JsonValue::Object(_)) = obj.get("config") {
            // Re-encode just the config object for api_base extraction.
            return evt.metadata_json.clone();
        }
    }
    "{}".to_string()
}

fn api_base_from(config_json: &str) -> String {
    let parsed: Result<JsonValue, _> = config_json.parse();
    let base = match parsed {
        Ok(JsonValue::Object(obj)) => {
            let cfg = match obj.get("config") {
                Some(JsonValue::Object(c)) => Some(c),
                _ => obj.get("api_base").map(|_| &obj),
            };

            cfg.and_then(|c| c.get("api_base"))
                .and_then(|v| v.get::<String>())
                .cloned()
        }
        _ => None,
    };

    base.unwrap_or_else(|| DEFAULT_API_BASE.to_string())
}

// ── Unit tests ────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn item_key_prefers_imdb_then_tmdb_then_tvdb() {
        assert_eq!(
            item_key(Some("tt1"), Some(2), Some(3), None, None),
            "imdb:tt1"
        );
        assert_eq!(item_key(None, Some(2), Some(3), None, None), "tmdb:2");
        assert_eq!(item_key(None, None, Some(3), None, None), "tvdb:3");
    }

    #[test]
    fn item_key_includes_episode_coordinates() {
        assert_eq!(
            item_key(None, None, Some(555), Some(1), Some(2)),
            "tvdb:555:s1e2"
        );
    }

    #[test]
    fn build_history_body_splits_movies_and_episodes() {
        let items = vec![
            PushItem {
                imdb: Some("tt100".into()),
                tmdb: None,
                tvdb: None,
                season: None,
                episode: None,
                updated_at: "t".into(),
                key: "imdb:tt100".into(),
            },
            PushItem {
                imdb: None,
                tmdb: None,
                tvdb: Some(555),
                season: Some(1),
                episode: Some(2),
                updated_at: "t".into(),
                key: "tvdb:555:s1e2".into(),
            },
        ];

        let body = build_history_body(&items);
        assert!(body.contains("\"movies\":[{\"ids\":{\"imdb\":\"tt100\"}}]"));
        assert!(body.contains("\"episodes\":[{\"ids\":{\"tvdb\":555},\"season\":1,\"episode\":2}]"));
    }

    // A trimmed but structurally faithful capture of Simkl's real
    // `/sync/all-items?episode_watched_at=yes&extended=full` response: three
    // top-level arrays, ids nested under `show`/`movie`, string-typed tvdb/tmdb,
    // and per-episode `watched_at` under `seasons[].episodes[]`.
    const REAL_ALL_ITEMS: &str = r#"{
        "shows": [
            {
                "status": "watching",
                "show": { "title": "Sherlock", "ids": { "tvdb": "176941", "tmdb": "19885" } },
                "seasons": [
                    {
                        "number": 1,
                        "episodes": [
                            { "number": 1, "watched_at": "2013-12-01T20:06:00Z" },
                            { "number": 2, "watched_at": "2013-12-02T20:06:00Z" }
                        ]
                    }
                ]
            }
        ],
        "anime": [
            {
                "status": "watching",
                "show": { "title": "Cowboy Bebop", "ids": { "tvdb": "76885", "tmdb": "30991" } },
                "seasons": [
                    { "number": 1, "episodes": [ { "number": 1, "watched_at": "2014-01-01T00:00:00Z" } ] }
                ]
            }
        ],
        "movies": [
            {
                "status": "completed",
                "last_watched_at": "2014-02-01T00:00:00Z",
                "movie": { "title": "Inception", "ids": { "imdb": "tt1375666", "tmdb": "27205" } }
            }
        ]
    }"#;

    // A trimmed capture of Simkl's real `/sync/activities`: a top-level `all`
    // alongside nested per-type objects and a `null` sibling.
    const REAL_ACTIVITIES: &str = r#"{
        "all": "2024-06-01T00:00:00Z",
        "tv_shows": { "all": "2024-05-30T00:00:00Z", "rated_at": "2024-05-29T00:00:00Z" },
        "anime": { "all": "2024-05-28T00:00:00Z" },
        "movies": { "all": "2024-05-27T00:00:00Z" },
        "settings": { "all": null }
    }"#;

    #[test]
    fn parse_activities_reads_the_all_timestamp() {
        assert_eq!(
            parse_activities(r#"{"all":"2024-01-01T00:00:00Z"}"#),
            Some("2024-01-01T00:00:00Z".to_string())
        );
        assert_eq!(parse_activities("{}"), None);
    }

    #[test]
    fn parse_activities_reads_all_from_real_body() {
        // The real body's nested objects and `null` siblings must not abort the
        // top-level `all` read (R-PULL-3).
        assert_eq!(
            parse_activities(REAL_ACTIVITIES),
            Some("2024-06-01T00:00:00Z".to_string())
        );
    }

    #[test]
    fn parse_activities_returns_none_without_top_level_all() {
        // A body that only has nested per-type `all`s (no top-level one) has no
        // cursor.
        assert_eq!(
            parse_activities(r#"{"tv_shows":{"all":"2024-05-30T00:00:00Z"}}"#),
            None
        );
    }

    #[test]
    fn parse_all_items_reads_a_show_with_string_tvdb() {
        // AE1: a shows entry with a string tvdb and two watched episodes yields
        // two items with the tvdb coerced to i64 and the right coordinates.
        let body = r#"{
            "shows": [
                {
                    "show": { "ids": { "tvdb": "320724" } },
                    "seasons": [
                        { "number": 1, "episodes": [
                            { "number": 1, "watched_at": "2013-12-01T20:06:00Z" },
                            { "number": 2, "watched_at": "2013-12-02T20:06:00Z" }
                        ] }
                    ]
                }
            ]
        }"#;
        let items = parse_all_items(body);
        assert_eq!(items.len(), 2);
        assert_eq!(items[0].tvdb, Some(320724));
        assert_eq!(items[0].season, Some(1));
        assert_eq!(items[0].episode, Some(1));
        assert_eq!(items[0].key(), "tvdb:320724:s1e1");
        assert_eq!(items[1].key(), "tvdb:320724:s1e2");
    }

    #[test]
    fn parse_all_items_reads_anime_like_a_show() {
        let body = r#"{
            "anime": [
                {
                    "show": { "ids": { "tvdb": "76885" } },
                    "seasons": [ { "number": 1, "episodes": [ { "number": 4, "watched_at": "2014-01-01T00:00:00Z" } ] } ]
                }
            ]
        }"#;
        let items = parse_all_items(body);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].key(), "tvdb:76885:s1e4");
        assert_eq!(items[0].watched_at.as_deref(), Some("2014-01-01T00:00:00Z"));
    }

    #[test]
    fn parse_all_items_reads_a_completed_movie() {
        let body = r#"{
            "movies": [
                {
                    "status": "completed",
                    "last_watched_at": "2014-02-01T00:00:00Z",
                    "movie": { "ids": { "imdb": "tt1375666" } }
                }
            ]
        }"#;
        let items = parse_all_items(body);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].season, None);
        assert_eq!(items[0].episode, None);
        assert_eq!(items[0].key(), "imdb:tt1375666");
        assert_eq!(items[0].watched_at.as_deref(), Some("2014-02-01T00:00:00Z"));
    }

    #[test]
    fn parse_all_items_skips_episodes_without_watched_at() {
        // Only watched episodes pull; an episode with no `watched_at` is skipped.
        let body = r#"{
            "shows": [
                {
                    "show": { "ids": { "tvdb": "1" } },
                    "seasons": [ { "number": 1, "episodes": [
                        { "number": 1, "watched_at": "2013-12-01T20:06:00Z" },
                        { "number": 2 }
                    ] } ]
                }
            ]
        }"#;
        let items = parse_all_items(body);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].episode, Some(1));
    }

    #[test]
    fn parse_all_items_accepts_numeric_ids_too() {
        // KTD3 both directions: tvdb/tmdb supplied as JSON numbers still parse.
        let body = r#"{
            "shows": [
                {
                    "show": { "ids": { "tvdb": 320724, "tmdb": 67195 } },
                    "seasons": [ { "number": 1, "episodes": [ { "number": 1, "watched_at": "2013-12-01T20:06:00Z" } ] } ]
                }
            ],
            "movies": [
                { "status": "completed", "last_watched_at": "2014-02-01T00:00:00Z", "movie": { "ids": { "tmdb": 27205 } } }
            ]
        }"#;
        let items = parse_all_items(body);
        assert_eq!(items.len(), 2);
        assert_eq!(items[0].tvdb, Some(320724));
        assert_eq!(items[0].tmdb, Some(67195));
        assert_eq!(items[1].tmdb, Some(27205));
    }

    #[test]
    fn parse_all_items_show_without_seasons_contributes_nothing() {
        // Params absent / nothing watched: a show with no `seasons` yields no
        // items and does not error.
        let body = r#"{
            "shows": [ { "status": "watching", "show": { "ids": { "tvdb": "1" } } } ]
        }"#;
        assert!(parse_all_items(body).is_empty());
    }

    #[test]
    fn parse_all_items_entry_missing_ids_is_skipped() {
        // An entry with no ids is skipped rather than panicking.
        let body = r#"{
            "shows": [ { "show": { "title": "No Ids" },
                        "seasons": [ { "number": 1, "episodes": [ { "number": 1, "watched_at": "t" } ] } ] } ],
            "movies": [ { "status": "completed", "movie": { "title": "No Ids" } } ]
        }"#;
        assert!(parse_all_items(body).is_empty());
    }

    #[test]
    fn parse_all_items_pulled_key_matches_push_side() {
        // Echo-guard alignment: the pulled episode's key equals the key the push
        // side computes for the same episode coordinates.
        let body = r#"{
            "shows": [
                {
                    "show": { "ids": { "tvdb": "555" } },
                    "seasons": [ { "number": 1, "episodes": [ { "number": 2, "watched_at": "t" } ] } ]
                }
            ]
        }"#;
        let pulled = parse_all_items(body);
        assert_eq!(pulled.len(), 1);

        let push = PushItem::from_progress(&PlaybackProgress {
            user_id: "u".into(),
            item_type: "episode".into(),
            media_item_id: None,
            episode_id: None,
            tmdb_id: None,
            tvdb_id: Some(555),
            imdb_id: None,
            season_number: Some(1),
            episode_number: Some(2),
            watched: true,
            last_watched_at: None,
            updated_at: "t".into(),
        })
        .unwrap();

        assert_eq!(pulled[0].key(), push.key);
        assert_eq!(pulled[0].key(), "tvdb:555:s1e2");
    }

    #[test]
    fn parse_all_items_real_capture_is_non_empty() {
        // The direct regression for "pulled 0 against 179 items": the real
        // multi-type response must produce a non-empty list.
        let items = parse_all_items(REAL_ALL_ITEMS);
        // 2 (Sherlock eps) + 1 (anime ep) + 1 (movie) = 4.
        assert_eq!(items.len(), 4);
    }

    #[test]
    fn string_array_round_trips() {
        let mut set = BTreeSet::new();
        set.insert("a".to_string());
        set.insert("b".to_string());
        let json = string_array_json(&set);
        let back: BTreeSet<String> = parse_string_array(&json).into_iter().collect();
        assert_eq!(set, back);
    }

    const MINI_MOVIES: &str = r#"{
        "movies": [
            { "status": "plantowatch", "movie": { "ids": { "imdb": "tt0111161", "tmdb": "278" } } },
            { "status": "plantowatch", "movie": { "ids": { "simkl": 4242 } } }
        ]
    }"#;

    const MINI_SHOWS: &str = r#"{
        "shows": [
            { "status": "plantowatch", "show": { "ids": { "tvdb": "320724", "tmdb": "67195" } } }
        ]
    }"#;

    #[test]
    fn parse_mini_list_reads_movie_ids() {
        let entries = parse_mini_list(MINI_MOVIES, false);
        assert_eq!(entries.len(), 1, "an entry with no usable id is skipped");
        assert_eq!(entries[0].imdb.as_deref(), Some("tt0111161"));
        assert_eq!(entries[0].key, "imdb:tt0111161");
        assert!(!entries[0].is_show);
    }

    #[test]
    fn parse_mini_list_reads_show_ids_as_strings() {
        let entries = parse_mini_list(MINI_SHOWS, true);
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].tvdb, Some(320_724));
        assert!(entries[0].is_show);
        assert_eq!(entries[0].key, "tmdb:67195");
    }

    #[test]
    fn parse_mini_list_of_garbage_is_empty_not_an_error() {
        assert!(parse_mini_list("not json", false).is_empty());
        assert!(parse_mini_list("{}", true).is_empty());
    }

    #[test]
    fn build_add_to_list_body_splits_movies_and_shows() {
        let items = vec![
            ListEntry {
                imdb: Some("tt0111161".to_string()),
                tmdb: None,
                tvdb: None,
                is_show: false,
                key: "imdb:tt0111161".to_string(),
            },
            ListEntry {
                imdb: None,
                tmdb: Some(67195),
                tvdb: Some(320_724),
                is_show: true,
                key: "tmdb:67195".to_string(),
            },
        ];

        let body = build_add_to_list_body(&items);
        assert!(body.contains("\"movies\""));
        assert!(body.contains("\"shows\""));
        assert!(body.contains("\"to\":\"plantowatch\""));
        assert!(body.contains("tt0111161"));
        assert!(body.contains("320724"));
    }

    #[test]
    fn intent_key_matches_the_pulled_key_for_the_same_item() {
        assert_eq!(
            intent_key(Some("tt0111161"), Some(278), None),
            item_key(Some("tt0111161"), Some(278), None, None, None)
        );
    }

    #[test]
    fn local_intent_set_holds_owned_and_unwatched_only() {
        let library = vec![
            lib_item("owned-unwatched", "movie", Some("tt1"), true),
            lib_item("owned-watched", "movie", Some("tt2"), true),
            lib_item("catalogued-only", "movie", Some("tt3"), false),
        ];
        let progress = vec![progress_row("u1", "movie", Some("tt2"))];

        let set = local_intent_set(&library, &progress, "u1");

        assert!(set.contains("imdb:tt1"));
        assert!(!set.contains("imdb:tt2"), "any progress removes an item");
        assert!(!set.contains("imdb:tt3"), "not owned is not intent");
    }

    #[test]
    fn local_intent_set_ignores_another_users_progress() {
        let library = vec![lib_item("owned-unwatched", "movie", Some("tt1"), true)];
        let progress = vec![progress_row("someone-else", "movie", Some("tt1"))];

        assert!(local_intent_set(&library, &progress, "u1").contains("imdb:tt1"));
    }

    #[test]
    fn local_intent_set_drops_a_show_with_any_watched_episode() {
        let library = vec![lib_item("show", "tv_show", Some("tt9"), true)];
        // An episode progress row carries the *show's* external ids, which is
        // why the intent key must ignore episode coordinates.
        let mut row = progress_row("u1", "episode", Some("tt9"));
        row.season_number = Some(1);
        row.episode_number = Some(3);

        assert!(local_intent_set(&library, &[row], "u1").is_empty());
    }

    // ── test builders ────────────────────────────────────────────────────────

    fn lib_item(id: &str, item_type: &str, imdb: Option<&str>, owned: bool) -> LibraryItem {
        LibraryItem {
            id: id.to_string(),
            item_type: item_type.to_string(),
            title: id.to_string(),
            year: None,
            tmdb_id: None,
            tvdb_id: None,
            imdb_id: imdb.map(|s| s.to_string()),
            owned,
            updated_at: "2026-08-11T00:00:00Z".to_string(),
        }
    }

    fn progress_row(user: &str, item_type: &str, imdb: Option<&str>) -> PlaybackProgress {
        PlaybackProgress {
            user_id: user.to_string(),
            item_type: item_type.to_string(),
            media_item_id: None,
            episode_id: None,
            tmdb_id: None,
            tvdb_id: None,
            imdb_id: imdb.map(|s| s.to_string()),
            season_number: None,
            episode_number: None,
            watched: true,
            last_watched_at: None,
            updated_at: "2026-08-11T00:00:00Z".to_string(),
        }
    }
}
