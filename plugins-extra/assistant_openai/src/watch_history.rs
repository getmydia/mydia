//! The `watch_history` tool: the user's recent watches, newest first, with
//! titles resolved through `data-read`.

use std::collections::HashMap;
use std::time::{SystemTime, UNIX_EPOCH};

use mydia_plugin_sdk::host;
use mydia_plugin_sdk::types::{DataRequest, ListItem, ListRequest, PlaybackProgress, ReadResult};
use serde_json::{json, Value};

use crate::tools::{clip, host_error_text};

const MAX_LIMIT: i64 = 50;
const DEFAULT_LIMIT: u32 = 20;
const MAX_DAYS: i64 = 3650;

/// Title and year per media_item_id; `None` when the lookup failed.
type Titles = HashMap<String, Option<(String, Option<u32>)>>;

pub fn definition() -> Value {
    json!({"type":"function","function":{
      "name":"watch_history",
      "description":"The user's recent watches, newest first: movies and episodes with title, status (watched or in_progress), percent, last_watched_at and source. source is \"Mydia\" for plays here, \"Plex sync\" or \"Simkl sync\" for watches imported from another service (their dates can be the sync time), or \"other\". An empty list means nothing has been watched yet; say so plainly.",
      "parameters":{"type":"object","properties":{
        "limit":{"type":"integer","minimum":1,"maximum":MAX_LIMIT},
        "days":{"type":"integer","minimum":0,"maximum":MAX_DAYS}
      },"required":[]}}})
}

fn bounded(a: &Value, k: &str, lo: i64, hi: i64) -> Result<(), String> {
    match a.get(k) {
        None | Some(Value::Null) => Ok(()),
        Some(v) => match v.as_i64() {
            Some(n) if (lo..=hi).contains(&n) => Ok(()),
            _ => Err(format!("{k} must be an integer from {lo} to {hi}")),
        },
    }
}

pub fn validate(a: &Value) -> Result<(), String> {
    bounded(a, "limit", 1, MAX_LIMIT)?;
    bounded(a, "days", 0, MAX_DAYS)
}

pub fn source_label(origin: Option<&str>) -> &'static str {
    match origin {
        Some("player") => "Mydia",
        Some(o) if is_plugin_origin(o, "plex") => "Plex sync",
        Some(o) if is_plugin_origin(o, "simkl_sync") => "Simkl sync",
        _ => "other",
    }
}

/// `plugin:<slug>` or `plugin:<slug>:<instance>`, but not a longer slug.
fn is_plugin_origin(origin: &str, slug: &str) -> bool {
    origin
        .strip_prefix("plugin:")
        .and_then(|rest| rest.strip_prefix(slug))
        .is_some_and(|tail| tail.is_empty() || tail.starts_with(':'))
}

pub fn percent(position: Option<u32>, duration: Option<u32>) -> Option<u32> {
    match (position, duration) {
        (Some(p), Some(d)) if d > 0 => Some(((p as f64 / d as f64) * 100.0).round().min(100.0) as u32),
        _ => None,
    }
}

/// RFC3339 UTC text for Unix seconds (days-from-civil inverse, Howard Hinnant).
pub fn rfc3339_utc(secs: i64) -> String {
    let days = secs.div_euclid(86_400);
    let rem = secs.rem_euclid(86_400);
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + if m <= 2 { 1 } else { 0 };
    format!("{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z", rem / 3600, rem % 3600 / 60, rem % 60)
}

pub fn row(p: &PlaybackProgress, titles: &Titles) -> Value {
    let found = p.media_item_id.as_ref().and_then(|id| titles.get(id)).and_then(|t| t.as_ref());
    let (title, year) = match found {
        Some((t, y)) => (clip(t, 200), *y),
        None => ("Unknown".to_string(), None),
    };
    json!({
        "title": title, "year": year, "type": p.item_type,
        "season": p.season_number, "episode": p.episode_number,
        "status": if p.watched { "watched" } else { "in_progress" },
        "percent": percent(p.position_seconds, p.duration_seconds),
        "last_watched_at": p.last_watched_at,
        "source": source_label(p.origin.as_deref()),
    })
}

fn since(days: Option<i64>) -> Option<String> {
    let days = days?;
    let now = SystemTime::now().duration_since(UNIX_EPOCH).ok()?.as_secs() as i64;
    Some(rfc3339_utc(now - days * 86_400))
}

fn resolve(ids: impl Iterator<Item = String>) -> Titles {
    let mut titles = Titles::new();
    for id in ids {
        if titles.contains_key(&id) {
            continue;
        }
        let found = match host::data_read(&DataRequest { namespace: "media_item".into(), id: id.clone() }) {
            Ok(ReadResult::MediaItem(m)) => Some((m.title, m.year)),
            _ => None,
        };
        titles.insert(id, found);
    }
    titles
}

pub fn run(a: &Value) -> Value {
    let limit = a["limit"].as_i64().map(|n| n as u32).unwrap_or(DEFAULT_LIMIT);
    let req = ListRequest {
        namespace: "watch_history".into(),
        cursor: None,
        updated_since: since(a["days"].as_i64()),
        limit: Some(limit),
    };
    let page = match host::data_list(&req) {
        Ok(page) => page,
        Err(e) => return json!({"error": host_error_text(&e)}),
    };
    let progress: Vec<&PlaybackProgress> = page
        .items
        .iter()
        .filter_map(|i| match i {
            ListItem::PlaybackProgress(p) => Some(p),
            _ => None,
        })
        .collect();
    let titles = resolve(progress.iter().filter_map(|p| p.media_item_id.clone()));
    json!(progress.iter().map(|p| row(p, &titles)).collect::<Vec<_>>())
}

#[cfg(test)]
mod tests {
    use super::*;
    use mydia_plugin_sdk::types::PlaybackProgress;
    use serde_json::json;
    use std::collections::HashMap;

    fn progress(item_type: &str, id: Option<&str>) -> PlaybackProgress {
        PlaybackProgress {
            user_id: "u".into(),
            item_type: item_type.into(),
            media_item_id: id.map(String::from),
            episode_id: None,
            tmdb_id: None,
            tvdb_id: None,
            imdb_id: None,
            season_number: None,
            episode_number: None,
            watched: false,
            position_seconds: Some(300),
            duration_seconds: Some(1200),
            last_watched_at: Some("2026-09-29T20:00:00Z".into()),
            updated_at: "2026-09-29T20:00:00Z".into(),
            origin: Some("player".into()),
        }
    }

    #[test]
    fn sources_are_normalized() {
        assert_eq!(source_label(Some("player")), "Mydia");
        assert_eq!(source_label(Some("plugin:plex:abc")), "Plex sync");
        assert_eq!(source_label(Some("plugin:simkl_sync:x")), "Simkl sync");
        assert_eq!(source_label(Some("plugin:plex")), "Plex sync");
        assert_eq!(source_label(Some("plugin:simkl_sync")), "Simkl sync");
        assert_eq!(source_label(Some("plugin:plexfoo")), "other");
        assert_eq!(source_label(Some("plugin:other:x")), "other");
        assert_eq!(source_label(None), "other");
    }

    #[test]
    fn percent_handles_missing_and_zero() {
        assert_eq!(percent(Some(300), Some(1200)), Some(25));
        assert_eq!(percent(Some(1300), Some(1200)), Some(100));
        assert_eq!(percent(None, Some(1200)), None);
        assert_eq!(percent(Some(10), Some(0)), None);
        assert_eq!(percent(Some(10), None), None);
    }

    #[test]
    fn rfc3339_formats_utc() {
        assert_eq!(rfc3339_utc(0), "1970-01-01T00:00:00Z");
        assert_eq!(rfc3339_utc(1_700_000_000), "2023-11-14T22:13:20Z");
    }

    #[test]
    fn rows_carry_title_status_and_source() {
        let mut titles = HashMap::new();
        titles.insert("m1".to_string(), Some(("Ember Tide".to_string(), Some(2024u32))));
        let mut ep = progress("episode", Some("m1"));
        ep.season_number = Some(2);
        ep.episode_number = Some(4);
        ep.watched = true;
        ep.origin = Some("plugin:plex:abc".into());

        assert_eq!(
            row(&ep, &titles),
            json!({"title": "Ember Tide", "year": 2024, "type": "episode", "season": 2, "episode": 4,
                   "status": "watched", "percent": 25, "last_watched_at": "2026-09-29T20:00:00Z",
                   "source": "Plex sync"})
        );
    }

    #[test]
    fn unresolved_titles_fall_back_to_unknown() {
        let titles: HashMap<String, Option<(String, Option<u32>)>> =
            HashMap::from([("gone".to_string(), None)]);
        let r = row(&progress("movie", Some("gone")), &titles);
        assert_eq!(r["title"], "Unknown");
        assert_eq!(r["status"], "in_progress");
        assert!(r["year"].is_null());
        let r = row(&progress("movie", None), &HashMap::new());
        assert_eq!(r["title"], "Unknown");
    }

    #[test]
    fn arguments_are_checked() {
        assert!(validate(&json!({})).is_ok());
        assert!(validate(&json!({"limit": 20, "days": 7})).is_ok());
        assert!(validate(&json!({"limit": 0})).is_err());
        assert!(validate(&json!({"limit": 51})).is_err());
        assert!(validate(&json!({"days": -1})).is_err());
        assert!(validate(&json!({"days": 3651})).is_err());
        assert!(validate(&json!({"days": "week"})).is_err());
    }
}
