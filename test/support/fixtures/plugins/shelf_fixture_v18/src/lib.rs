//! Shelf fixture (1.8): see Cargo.toml. Echoes catalog hits' vote counts.

use mydia_plugin_sdk::host;
use mydia_plugin_sdk::types::{
    Event, MediaRef, SearchKind, SearchRequest, ShelfItem, ShelfRequest,
};

fn handle_fill(req: ShelfRequest) -> Result<Vec<ShelfItem>, String> {
    let hits = host::search(&SearchRequest {
        kind: SearchKind::Catalog,
        query: req.shelf,
        media_type: Some("movie".into()),
        limit: Some(10),
    })
    .map_err(|e| format!("{:?}", e))?;

    Ok(hits
        .into_iter()
        .map(|h| {
            let votes = h
                .vote_count
                .map(|v| v.to_string())
                .unwrap_or_else(|| "none".into());
            ShelfItem {
                item: MediaRef {
                    media_type: "movie".into(),
                    tmdb_id: Some(h.tmdb_id.unwrap_or(0)),
                    tvdb_id: None,
                    imdb_id: None,
                },
                reason: Some(format!("{}/{}", h.title, votes)),
            }
        })
        .collect())
}

#[mydia_plugin_sdk::plugin(fill_shelf = handle_fill)]
fn on_event(_evt: Event) -> Result<String, String> {
    Ok("{}".into())
}
