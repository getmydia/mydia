//! Shelf fixture (1.7): see Cargo.toml. Echoes `feedback` back as shelf items.

use mydia_plugin_sdk::host;
use mydia_plugin_sdk::types::{
    Event, MediaRef, ShelfFeedback, ShelfItem, ShelfRating, ShelfRequest, ShelfVia,
};

fn echo(f: ShelfFeedback) -> ShelfItem {
    let rating = match f.rating {
        ShelfRating::Up => "up",
        ShelfRating::Down => "down",
    };
    let via = match f.via {
        Some(ShelfVia::Added) => "added",
        Some(ShelfVia::Seen) => "seen",
        None => "none",
    };
    let year = f.year.map(|y| y.to_string()).unwrap_or_else(|| "none".into());
    ShelfItem {
        item: MediaRef {
            media_type: f.item.media_type,
            tmdb_id: Some(f.item.tmdb_id.unwrap_or(0)),
            tvdb_id: f.item.tvdb_id,
            imdb_id: None,
        },
        reason: Some(format!("{}/{}/{}/{}", rating, via, f.title, year)),
    }
}

fn handle_fill(req: ShelfRequest) -> Result<Vec<ShelfItem>, String> {
    // Importing a host function is what lets the host detect the contract.
    host::log("info", &format!("feedback entries: {}", req.feedback.len()));
    Ok(req.feedback.into_iter().map(echo).collect())
}

#[mydia_plugin_sdk::plugin(fill_shelf = handle_fill)]
fn on_event(_evt: Event) -> Result<String, String> {
    Ok("{}".into())
}
