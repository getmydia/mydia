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
      f("list", "List the user's collections, media requests, active downloads or watch progress.",
        json!({"what":{"type":"string","enum":["collection","media_request","download","playback_progress"]}}), vec!["what"]),
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
        json!({"tmdb_id":{"type":"integer"},"tvdb_id":{"type":"integer"},"imdb_id":{"type":"string"}}), vec![])
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

fn err(e: HostError) -> Outcome {
    text(json!({"error": format!("{e:?}")}))
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
    match name {
        "search_library" | "search_catalog" => {
            let kind = if name == "search_library" { SearchKind::Library } else { SearchKind::Catalog };
            match host::search(&SearchRequest { kind, query: s(a, "query").unwrap_or_default(), media_type: s(a, "media_type"), limit: Some(10) }) {
                Ok(hits) => text(json!(hits.iter().map(|h| json!({
                    "title": h.title, "year": h.year, "type": h.item_type,
                    "media_item_id": h.media_item_id, "tmdb_id": h.tmdb_id, "tvdb_id": h.tvdb_id,
                    "overview": h.overview.as_ref().map(|o| o.chars().take(200).collect::<String>())
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
            season_number: i(a, "season").map(|n| n as u32), episode_number: i(a, "episode").map(|n| n as u32),
            watched: a["watched"].as_bool().unwrap_or(true), position_seconds: None, duration_seconds: None, watched_at: None,
        })),
        "add_favorite" => write(host::add_favorite(&FavoriteTarget { user_id: String::new(), imdb_id: s(a, "imdb_id"), tmdb_id: i(a, "tmdb_id"), tvdb_id: i(a, "tvdb_id") })),
        other => text(json!({"error": format!("unknown tool {other}")})),
    }
}

fn list_item(item: &ListItem) -> Value {
    match item {
        ListItem::Collection(c) => json!({"id": c.id, "name": c.name, "kind": c.kind, "items": c.item_count}),
        ListItem::MediaRequest(r) => json!({"title": r.title, "status": r.status, "year": r.year}),
        ListItem::Download(d) => json!({"title": d.title, "status": d.status, "progress": d.progress, "eta_seconds": d.eta_seconds}),
        ListItem::PlaybackProgress(p) => json!({"type": p.item_type, "media_item_id": p.media_item_id, "season": p.season_number, "episode": p.episode_number, "watched": p.watched}),
        ListItem::MediaItem(m) => json!({"id": m.id, "title": m.title, "year": m.year}),
        ListItem::LibraryItem(l) => json!({"id": l.id, "title": l.title, "year": l.year, "owned": l.owned}),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_tool_has_a_name_and_parameters() {
        let defs = definitions();
        let arr = defs.as_array().unwrap();
        assert_eq!(arr.len(), 10);
        for d in arr {
            assert!(d["function"]["name"].is_string());
            assert_eq!(d["function"]["parameters"]["type"], "object");
        }
    }
}
