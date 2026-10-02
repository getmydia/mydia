//! Shelf fixture: see Cargo.toml for the behaviour table.

use mydia_plugin_sdk::host;
use mydia_plugin_sdk::types::{
    Event, ListRequest, MediaAddTarget, MediaRef, SearchKind, SearchRequest, ShelfItem,
    ShelfRequest,
};

fn item(media_type: &str, tmdb_id: i64, reason: Option<String>) -> ShelfItem {
    ShelfItem {
        item: MediaRef {
            media_type: media_type.into(),
            tmdb_id: Some(tmdb_id),
            tvdb_id: None,
            imdb_id: None,
        },
        reason,
    }
}

fn handle_fill(req: ShelfRequest) -> Result<Vec<ShelfItem>, String> {
    match req.shelf.as_str() {
        "fixed" => Ok(vec![
            item("movie", 101, Some("Because you finished Ember Tide".into())),
            item("tv_show", 202, None),
            item("movie", 303, Some("More slow-burn mysteries".into())),
        ]),

        "echo" => Ok(vec![item(
            "movie",
            req.limit as i64,
            Some(format!(
                "{}|{}|{}",
                req.user_id.unwrap_or_default(),
                req.exclude.len(),
                req.config_json
            )),
        )]),

        "search" => {
            let hits = host::search(&SearchRequest {
                kind: SearchKind::Library,
                query: "Ember".into(),
                media_type: None,
                limit: Some(10),
            })
            .map_err(|e| format!("{:?}", e))?;
            let titles: Vec<String> = hits.into_iter().map(|h| h.title).collect();
            Ok(vec![item("movie", 1, Some(titles.join(",")))])
        }

        "history" => {
            let page = host::data_list(&ListRequest {
                namespace: "watch_history".into(),
                cursor: None,
                updated_since: None,
                limit: Some(50),
            })
            .map_err(|e| format!("{:?}", e))?;
            Ok(vec![item("movie", 1, Some(page.items.len().to_string()))])
        }

        "write" => {
            host::media_add(&MediaAddTarget {
                media_type: "movie".into(),
                tmdb_id: Some(101),
                tvdb_id: None,
            })
            .map_err(|e| format!("{:?}", e))?;
            Ok(vec![item("movie", 101, Some("wrote".into()))])
        }

        "fail" => Err("boom".into()),

        _ => Ok(vec![]),
    }
}

#[mydia_plugin_sdk::plugin(fill_shelf = handle_fill)]
fn on_event(_evt: Event) -> Result<String, String> {
    Ok("{}".into())
}
