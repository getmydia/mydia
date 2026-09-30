//! Tool definitions offered to the model, and their execution against the host.

use mydia_plugin_sdk::host;
use mydia_plugin_sdk::types::{
    CollectionAttrs, FavoriteTarget, HostError, ListItem, ListRequest, MediaAddTarget,
    SearchKind, SearchRequest, WatchStateTarget, WriteOutcome,
};
use serde_json::{json, Value};

pub fn definitions() -> Value {
    let f = |name: &str, desc: &str, props: Value, required: Vec<&str>| {
        json!({"type":"function","function":{"name":name,"description":desc,
          "parameters":{"type":"object","properties":props,"required":required}}})
    };
    let media_type = json!({"type":"string","enum":["movie","tv_show"]});
    let ids = json!({"type":"array","items":{"type":"string"}});
    json!([
      f("search_library", "Search the user's library. Returns titles with media_item_id.",
        json!({"query":{"type":"string"},"media_type":media_type}), vec!["query"]),
      f("search_catalog", "Search the movie and TV catalog for things not in the library. Returns tmdb_id or tvdb_id.",
        json!({"query":{"type":"string"},"media_type":media_type}), vec!["query"]),
      f("list", "List the user's collections, media requests or active downloads.",
        json!({"what":{"type":"string","enum":["collection","media_request","download"]}}), vec!["what"]),
      f("add_media", "Add a movie or show to the library (or request it, depending on the user's role).",
        json!({"media_type":media_type,"tmdb_id":{"type":"integer"},"tvdb_id":{"type":"integer"}}), vec!["media_type"]),
      f("create_collection", "Create a manual collection, or a smart one from rules JSON.",
        json!({"name":{"type":"string"},"description":{"type":"string"},"kind":{"type":"string","enum":["manual","smart"]},"smart_rules_json":{"type":"string"}}), vec!["name"]),
      f("update_collection", "Rename or edit a collection the user owns.",
        json!({"id":{"type":"string"},"name":{"type":"string"},"description":{"type":"string"},"smart_rules_json":{"type":"string"}}), vec!["id"]),
      f("add_to_collection", "Add library items (media_item_id) to a manual collection.",
        json!({"id":{"type":"string"},"media_item_ids":ids}), vec!["id","media_item_ids"]),
      f("remove_from_collection", "Remove library items from a manual collection.",
        json!({"id":{"type":"string"},"media_item_ids":ids}), vec!["id","media_item_ids"]),
      f("set_watched", "Mark a movie, or an episode by season and episode number, watched or unwatched.",
        json!({"tmdb_id":{"type":"integer"},"tvdb_id":{"type":"integer"},"imdb_id":{"type":"string"},"season":{"type":"integer"},"episode":{"type":"integer"},"watched":{"type":"boolean"}}), vec!["watched"]),
      f("add_favorite", "Add a library item to the user's Favorites.",
        json!({"tmdb_id":{"type":"integer"},"tvdb_id":{"type":"integer"},"imdb_id":{"type":"string"}}), vec![]),
      crate::watch_history::definition()
    ])
}

/// What one tool call produced: text for the model and, for a write that needs
/// the user's approval, the pending id to hand to the page UI.
pub struct Outcome {
    pub content: String,
    pub pending: Option<String>,
}

fn text(v: Value) -> Outcome {
    Outcome { content: v.to_string(), pending: None }
}

/// Friendly, bounded text for a host error: the model and the page never see
/// Debug output.
pub fn host_error_text(e: &HostError) -> String {
    let (label, detail) = match e {
        HostError::Denied(d) => ("Not allowed", d),
        HostError::InvalidRequest(d) => ("Invalid request", d),
        HostError::NotFound(d) => ("Not found", d),
        HostError::Network(d) => ("Network problem", d),
        HostError::Internal(d) => ("Internal error", d),
    };
    format!("{label}: {}", clip(detail, 200))
}

fn err(e: HostError) -> Outcome {
    text(json!({"error": host_error_text(&e)}))
}

fn reject(msg: &str) -> Outcome {
    text(json!({"error": msg}))
}

/// Cuts a string to `max` characters, marking the cut.
pub fn clip(v: &str, max: usize) -> String {
    if v.chars().count() <= max {
        v.to_string()
    } else {
        let cut: String = v.chars().take(max).collect();
        format!("{cut}…")
    }
}

/// Most ids one call may carry, matching the host's confirmation cap.
pub const MAX_IDS: usize = 50;
const LIST_NAMESPACES: [&str; 3] = ["collection", "media_request", "download"];
const MEDIA_TYPES: [&str; 2] = ["movie", "tv_show"];

fn check_media_type(a: &Value, required: bool) -> Result<(), String> {
    match a.get("media_type") {
        None | Some(Value::Null) if !required => Ok(()),
        Some(Value::String(t)) if MEDIA_TYPES.contains(&t.as_str()) => Ok(()),
        _ => Err("media_type must be \"movie\" or \"tv_show\"".into()),
    }
}

fn check_u32(a: &Value, k: &str) -> Result<(), String> {
    match a.get(k) {
        None | Some(Value::Null) => Ok(()),
        Some(v) => v
            .as_i64()
            .and_then(|n| u32::try_from(n).ok())
            .map(|_| ())
            .ok_or_else(|| format!("{k} must be a non-negative integer")),
    }
}

fn check_ids(a: &Value) -> Result<(), String> {
    match a.get("media_item_ids").and_then(|v| v.as_array()) {
        Some(v) if v.len() > MAX_IDS => Err(format!("at most {MAX_IDS} media_item_ids per call")),
        Some(v) if v.iter().all(|x| x.is_string()) => Ok(()),
        _ => Err("media_item_ids must be a list of strings".into()),
    }
}

/// Checks a tool call's arguments before anything reaches the host.
pub fn validate(name: &str, a: &Value) -> Result<(), String> {
    if !a.is_object() {
        return Err("invalid arguments: expected a JSON object".into());
    }
    match name {
        "search_library" | "search_catalog" => check_media_type(a, false),
        "list" => match a["what"].as_str() {
            Some(w) if LIST_NAMESPACES.contains(&w) => Ok(()),
            _ => Err(format!("what must be one of {}", LIST_NAMESPACES.join(", "))),
        },
        "add_media" => check_media_type(a, true),
        "add_to_collection" | "remove_from_collection" => check_ids(a),
        "set_watched" => {
            if !a["watched"].is_boolean() {
                return Err("watched must be true or false".into());
            }
            check_u32(a, "season")?;
            check_u32(a, "episode")
        }
        "watch_history" => crate::watch_history::validate(a),
        _ => Ok(()),
    }
}

fn s(a: &Value, k: &str) -> Option<String> {
    a[k].as_str().map(|x| x.to_string())
}

fn i(a: &Value, k: &str) -> Option<i64> {
    a[k].as_i64()
}

fn strs(a: &Value, k: &str) -> Vec<String> {
    a[k].as_array().map(|v| v.iter().filter_map(|x| x.as_str().map(String::from)).collect()).unwrap_or_default()
}

pub fn write(r: Result<WriteOutcome, HostError>) -> Outcome {
    match r {
        Ok(WriteOutcome::Done(result)) => Outcome { content: json!({"done": true, "result": result}).to_string(), pending: None },
        Ok(WriteOutcome::NeedsConfirmation(id)) => Outcome {
            content: json!({"awaiting_user_approval": true, "note": "The user will approve or deny this in a dialog. Do not repeat it."}).to_string(),
            pending: Some(id),
        },
        Err(e) => err(e),
    }
}

pub fn run(name: &str, a: &Value) -> Outcome {
    if let Err(m) = validate(name, a) {
        return reject(&m);
    }
    match name {
        "search_library" | "search_catalog" => {
            let kind = if name == "search_library" { SearchKind::Library } else { SearchKind::Catalog };
            match host::search(&SearchRequest { kind, query: s(a, "query").unwrap_or_default(), media_type: s(a, "media_type"), limit: Some(10) }) {
                Ok(hits) => text(json!(hits.iter().map(|h| json!({
                    "title": clip(&h.title, 200), "year": h.year, "type": h.item_type,
                    "media_item_id": h.media_item_id, "tmdb_id": h.tmdb_id, "tvdb_id": h.tvdb_id,
                    "overview": h.overview.as_ref().map(|o| clip(o, 200))
                })).collect::<Vec<_>>())),
                Err(e) => err(e),
            }
        }
        "list" => {
            let ns = s(a, "what").unwrap_or_default();
            match host::data_list(&ListRequest { namespace: ns, cursor: None, updated_since: None, limit: Some(50) }) {
                Ok(page) => text(json!(page.items.iter().map(list_item).collect::<Vec<_>>())),
                Err(e) => err(e),
            }
        }
        "add_media" => write(host::media_add(&MediaAddTarget { media_type: s(a, "media_type").unwrap_or_default(), tmdb_id: i(a, "tmdb_id"), tvdb_id: i(a, "tvdb_id") })),
        "create_collection" => write(host::collection_create(&CollectionAttrs { name: s(a, "name"), description: s(a, "description"), kind: s(a, "kind"), smart_rules_json: s(a, "smart_rules_json") })),
        "update_collection" => write(host::collection_update(&s(a, "id").unwrap_or_default(), &CollectionAttrs { name: s(a, "name"), description: s(a, "description"), kind: None, smart_rules_json: s(a, "smart_rules_json") })),
        "add_to_collection" => write(host::collection_add_items(&s(a, "id").unwrap_or_default(), &strs(a, "media_item_ids"))),
        "remove_from_collection" => write(host::collection_remove_items(&s(a, "id").unwrap_or_default(), &strs(a, "media_item_ids"))),
        "set_watched" => write(host::mark_watched_state(&WatchStateTarget {
            user_id: String::new(), imdb_id: s(a, "imdb_id"), tmdb_id: i(a, "tmdb_id"), tvdb_id: i(a, "tvdb_id"),
            season_number: i(a, "season").and_then(|n| u32::try_from(n).ok()), episode_number: i(a, "episode").and_then(|n| u32::try_from(n).ok()),
            watched: a["watched"].as_bool().unwrap_or(false), position_seconds: None, duration_seconds: None, watched_at: None,
        })),
        "add_favorite" => write(host::add_favorite(&FavoriteTarget { user_id: String::new(), imdb_id: s(a, "imdb_id"), tmdb_id: i(a, "tmdb_id"), tvdb_id: i(a, "tvdb_id") })),
        "watch_history" => text(crate::watch_history::run(a)),
        other => text(json!({"error": format!("unknown tool {other}")})),
    }
}

fn list_item(item: &ListItem) -> Value {
    match item {
        ListItem::Collection(c) => json!({"id": c.id, "name": clip(&c.name, 200), "kind": c.kind, "items": c.item_count}),
        ListItem::MediaRequest(r) => json!({"title": clip(&r.title, 200), "status": r.status, "year": r.year}),
        ListItem::Download(d) => json!({"title": clip(&d.title, 200), "status": d.status, "progress": d.progress, "eta_seconds": d.eta_seconds}),
        ListItem::MediaItem(m) => json!({"id": m.id, "title": clip(&m.title, 200), "year": m.year}),
        ListItem::LibraryItem(l) => json!({"id": l.id, "title": clip(&l.title, 200), "year": l.year, "owned": l.owned}),
        _ => json!({}),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_tool_has_a_name_and_parameters() {
        let defs = definitions();
        let arr = defs.as_array().unwrap();
        assert_eq!(arr.len(), 11);
        for d in arr {
            assert!(d["function"]["name"].is_string());
            assert_eq!(d["function"]["parameters"]["type"], "object");
        }
    }

    fn rejected(name: &str, args: Value) -> bool {
        validate(name, &args).is_err()
    }

    #[test]
    fn list_no_longer_offers_playback_progress() {
        assert!(rejected("list", json!({"what": "playback_progress"})));
    }

    #[test]
    fn watch_history_arguments_are_validated() {
        assert!(rejected("watch_history", json!({"limit": 0})));
        assert!(validate("watch_history", &json!({"days": 7})).is_ok());
    }

    #[test]
    fn list_rejects_unknown_namespace() {
        assert!(rejected("list", json!({"what": "media_item"})));
        assert!(rejected("list", json!({})));
        assert!(validate("list", &json!({"what": "download"})).is_ok());
    }

    #[test]
    fn media_type_is_checked() {
        assert!(rejected("add_media", json!({})));
        assert!(rejected("add_media", json!({"media_type": "episode"})));
        assert!(rejected("search_library", json!({"query": "x", "media_type": "book"})));
        assert!(validate("search_library", &json!({"query": "x"})).is_ok());
        assert!(validate("add_media", &json!({"media_type": "movie"})).is_ok());
    }

    #[test]
    fn negative_or_huge_numbers_are_rejected() {
        assert!(rejected("set_watched", json!({"watched": true, "season": -1})));
        assert!(rejected("set_watched", json!({"watched": true, "episode": 5_000_000_000i64})));
        assert!(validate("set_watched", &json!({"watched": true, "season": 1, "episode": 2})).is_ok());
    }

    #[test]
    fn set_watched_requires_a_boolean() {
        assert!(rejected("set_watched", json!({"tmdb_id": 1})));
        assert!(rejected("set_watched", json!({"watched": "yes"})));
    }

    #[test]
    fn id_lists_are_capped_and_typed() {
        let many: Vec<String> = (0..=MAX_IDS).map(|n| n.to_string()).collect();
        assert!(rejected("add_to_collection", json!({"id": "c", "media_item_ids": many})));
        assert!(rejected("remove_from_collection", json!({"id": "c", "media_item_ids": [1, 2]})));
        assert!(rejected("add_to_collection", json!({"id": "c"})));
        assert!(validate("add_to_collection", &json!({"id": "c", "media_item_ids": ["a"]})).is_ok());
    }

    #[test]
    fn non_object_arguments_are_rejected() {
        assert!(rejected("list", json!("nope")));
    }

    #[test]
    fn write_maps_outcomes() {
        let done = write(Ok(WriteOutcome::Done("{\"id\":1}".into())));
        assert!(done.pending.is_none());
        assert!(done.content.contains("\"done\":true"));
        let pending = write(Ok(WriteOutcome::NeedsConfirmation("p1".into())));
        assert_eq!(pending.pending.as_deref(), Some("p1"));
        assert!(pending.content.contains("awaiting_user_approval"));
    }

    #[test]
    fn host_errors_are_friendly_and_clipped() {
        let t = host_error_text(&HostError::Denied("x".repeat(500)));
        assert!(t.starts_with("Not allowed: "));
        assert!(t.chars().count() < 230);
        assert!(!t.contains("Denied("));
    }

    #[test]
    fn clip_marks_the_cut() {
        assert_eq!(clip("abc", 5), "abc");
        assert_eq!(clip("abcdef", 3), "abc…");
    }
}
