//! on-event: library refresh after an import, and an immediate push when a
//! player finishes something. Runs under the 5 s event timeout, so it never
//! probes candidates or rediscovers (health::quick_base) and never crawls.

use crate::api;
use crate::endpoint;
use crate::health;
use crate::host::Host;
use crate::http::{Direction, PluginConfig};
use crate::mapping;
use crate::sync;
use crate::time;
use mydia_plugin_sdk::types::{
    Event, LinkRole, LinkStatus, ListItem, ListRequest, PlaybackProgress,
};
use serde_json::{json, Value};

/// How far back a playback.finished handler looks for the progress row the
/// event is about. Delivery takes seconds; five minutes absorbs a retry.
const FINISHED_LOOKBACK_SECONDS: i64 = 300;

pub fn handle(host: &mut dyn Host, evt: &Event) -> Result<String, String> {
    let meta: Value = serde_json::from_str(&evt.metadata_json).unwrap_or(Value::Null);
    let cfg = PluginConfig::parse(
        &meta
            .get("config")
            .cloned()
            .unwrap_or(Value::Null)
            .to_string(),
    );
    // `Plugins.build_payload/1` nests the event's own metadata bag under
    // "metadata"; the host injects "config" beside it (Host.to_event_record/1).
    let data = meta.get("metadata").cloned().unwrap_or(Value::Null);
    match evt.event.as_str() {
        "media_file.imported" => Ok(refresh(host, &cfg)),
        // Only player finishes: our own write-backs and other sync origins must
        // never trigger an immediate re-push.
        "playback.finished" if data.get("origin").and_then(Value::as_str) == Some("player") => {
            push_finished(host, evt, &data, &cfg);
            Ok("{}".into())
        }
        _ => Ok("{}".into()),
    }
}

/// Native Notifier.notify_all/0 refreshed every section, and the event carries
/// only the file's basename, so a path-scoped refresh is not possible.
fn refresh(host: &mut dyn Host, cfg: &PluginConfig) -> String {
    let result = health::quick_base(host, cfg)
        .and_then(|(base, link)| api::refresh(host, &base, &link, None));
    match result {
        Ok(()) => json!({"delivered": true}).to_string(),
        Err(e) => json!({"delivered": false, "error": e.message()}).to_string(),
    }
}

fn push_finished(host: &mut dyn Host, evt: &Event, meta: &Value, cfg: &PluginConfig) {
    if !cfg.sync_enabled() || cfg.direction() == Direction::Import {
        return;
    }
    let Some(user_id) = evt.actor_id.clone() else {
        return;
    };
    let media_item_id = meta.get("media_item_id").and_then(Value::as_str);
    let episode_id = meta.get("episode_id").and_then(Value::as_str);

    let Ok(links) = host.links_list() else {
        return;
    };
    let Some(link) = links.into_iter().find(|l| {
        l.role == LinkRole::User
            && l.status == LinkStatus::Active
            && l.user_id.as_deref() == Some(user_id.as_str())
    }) else {
        return;
    };
    let Ok((base, _)) = health::quick_base(host, cfg) else {
        return;
    };
    let Ok(owner) = endpoint::owner_link(host) else {
        return;
    };
    let Some(row) = find_row(host, &user_id, media_item_id, episode_id) else {
        return;
    };
    let Ok(Some(rk)) = mapping::lookup_rating_key(host, &row) else {
        return;
    };

    if let Err(e) = sync::push_one(host, &base, &owner, &link, cfg, &row, &rk) {
        host.log("warn", &format!("plex: immediate push failed: {e:?}"));
    }
}

fn find_row(
    host: &mut dyn Host,
    user_id: &str,
    media_item_id: Option<&str>,
    episode_id: Option<&str>,
) -> Option<PlaybackProgress> {
    let since = time::to_rfc3339(host.now() - FINISHED_LOOKBACK_SECONDS);
    let mut cursor: Option<String> = None;
    loop {
        let res = host
            .data_list(&ListRequest {
                namespace: "playback_progress".into(),
                cursor: cursor.clone(),
                updated_since: Some(since.clone()),
                limit: Some(crate::api::PAGE_SIZE),
            })
            .ok()?;
        for item in res.items {
            let ListItem::PlaybackProgress(p) = item else {
                continue;
            };
            let same_item = match (media_item_id, episode_id) {
                (_, Some(e)) => p.episode_id.as_deref() == Some(e),
                (Some(m), None) => p.media_item_id.as_deref() == Some(m) && p.episode_id.is_none(),
                (None, None) => false,
            };
            if p.user_id == user_id && same_item {
                return Some(p);
            }
        }
        cursor = Some(res.next_cursor?);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::host::fake::FakeHost;
    use crate::mapping::progress_row;
    use mydia_plugin_sdk::types::ListResult;

    const NOW: i64 = 1_767_225_600;
    const B: &str = "http://plex.test";

    fn event(name: &str, actor: Option<&str>, meta: Value) -> Event {
        Event {
            event: name.into(),
            category: None,
            severity: None,
            actor_type: Some("user".into()),
            actor_id: actor.map(str::to_string),
            resource_type: None,
            resource_id: None,
            metadata_json: meta.to_string(),
        }
    }

    fn config() -> Value {
        json!({"instance_id": "I1", "url": B, "sync_watched": "on"})
    }

    fn host() -> FakeHost {
        let mut h = FakeHost::new();
        h.now_value = NOW;
        h.with_link("owner", LinkRole::Owner, None, None);
        h
    }

    #[test]
    fn an_import_refreshes_every_section() {
        let mut h = host();
        let refresh = format!("{B}/library/sections/all/refresh");
        h.respond("GET", &refresh, 200, "");
        let out = handle(
            &mut h,
            &event(
                "media_file.imported",
                None,
                json!({"metadata": {"file_path": "x.mkv"}, "config": config()}),
            ),
        )
        .unwrap();
        assert_eq!(out, r#"{"delivered":true}"#);
        assert_eq!(h.requests_to(&refresh)[0].link.as_deref(), Some("owner"));
    }

    #[test]
    fn a_failed_refresh_asks_for_redelivery() {
        let mut h = host();
        let out = handle(
            &mut h,
            &event("media_file.imported", None, json!({"config": config()})),
        )
        .unwrap();
        let v: Value = serde_json::from_str(&out).unwrap();
        assert_eq!(v["delivered"], false);
    }

    #[test]
    fn a_non_player_finish_is_ignored() {
        let mut h = host();
        let meta = json!({"metadata": {"origin": "plugin:plex:I1", "media_item_id": "m1"}, "config": config()});
        assert_eq!(
            handle(&mut h, &event("playback.finished", Some("u1"), meta)).unwrap(),
            "{}"
        );
        assert!(h.sent.is_empty());
    }

    #[test]
    fn a_player_finish_scrobbles_that_item_now() {
        let mut h = host();
        h.with_link("L1", LinkRole::User, Some("uuid-u1"), Some("u1"));
        h.links.last_mut().unwrap().user_id = Some("u1".into());
        h.kv.insert("rev/movie/tmdb/4001".into(), "\"100\"".into());
        let mut row = progress_row("movie");
        row.media_item_id = Some("m1".into());
        row.tmdb_id = Some(4001);
        row.watched = true;
        h.data_pages.push_back(ListResult {
            items: vec![ListItem::PlaybackProgress(row)],
            next_cursor: None,
        });
        h.respond(
            "GET",
            &format!("{B}/library/metadata/100?includeGuids=1"),
            200,
            r#"{"MediaContainer":{"Metadata":[{"ratingKey":"100","type":"movie","viewCount":0}]}}"#,
        );
        let scrobble = format!("{B}/:/scrobble?identifier=com.plexapp.plugins.library&key=100");
        h.respond("GET", &scrobble, 200, "");

        let meta =
            json!({"metadata": {"origin": "player", "media_item_id": "m1"}, "config": config()});
        handle(&mut h, &event("playback.finished", Some("u1"), meta)).unwrap();

        assert_eq!(h.requests_to(&scrobble)[0].link.as_deref(), Some("L1"));
        assert_eq!(
            h.data_requests[0].updated_since.as_deref(),
            Some("2025-12-31T23:55:00Z")
        );
    }
}
