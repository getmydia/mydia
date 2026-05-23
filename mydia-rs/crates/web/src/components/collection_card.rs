//! Collection card — index-page grid tile (U26).
//!
//! Compact card showing a collage of up to four poster thumbnails, the
//! collection name, item count, and a type badge (manual / smart). The
//! Phoenix `CollectionComponents.collection_card` covers a richer
//! surface (per-card play CTA, edit menu, share badge); the Rust port
//! lands the read-side and leaves write affordances to follow-ups.

use dioxus::prelude::*;

use crate::components::core::Icon;
use crate::routes::Route;
use crate::server_fns::collections::CollectionListItem;

/// Prefix for TMDB poster paths. Matches `MediaCard` so the collage
/// thumbnails share the same density tuning.
const TMDB_POSTER_BASE: &str = "https://image.tmdb.org/t/p/w185";

#[derive(Props, Clone, PartialEq)]
pub struct CollectionCardProps {
    pub item: CollectionListItem,
}

#[component]
pub fn CollectionCard(props: CollectionCardProps) -> Element {
    let item = props.item;
    let target = Route::CollectionShow {
        id: item.id.clone(),
    };

    let count_label = if item.item_count == 1 {
        "1 item".to_owned()
    } else {
        format!("{} items", item.item_count)
    };

    rsx! {
        Link {
            to: target,
            class: "block group",
            div { class: "card card-compact bg-base-100 shadow-md overflow-hidden hover:shadow-2xl transition-shadow",
                figure { class: "aspect-[3/2] bg-base-300 relative overflow-hidden",
                    PosterCollage { poster_paths: item.poster_paths.clone() }

                    // Type badge — pinned top-right of the collage.
                    div { class: "absolute top-2 right-2 z-10",
                        if item.kind == "smart" {
                            span { class: "badge badge-secondary badge-sm shadow",
                                Icon { name: "sparkles".to_string(), class: "w-3 h-3 mr-1".to_string() }
                                "Smart"
                            }
                        } else {
                            span { class: "badge badge-primary badge-sm shadow",
                                Icon { name: "folder".to_string(), class: "w-3 h-3 mr-1".to_string() }
                                "Manual"
                            }
                        }
                    }
                    // System badge — bottom-left when applicable.
                    if item.is_system {
                        div { class: "absolute bottom-2 left-2 z-10",
                            span { class: "badge badge-ghost badge-sm shadow",
                                Icon { name: "star".to_string(), class: "w-3 h-3 mr-1".to_string() }
                                "System"
                            }
                        }
                    }
                }
                div { class: "card-body",
                    h3 { class: "card-title text-sm leading-snug line-clamp-1", "{item.name}" }
                    div { class: "flex items-center justify-between text-xs opacity-70",
                        span { "{count_label}" }
                        if item.visibility == "shared" {
                            span { class: "badge badge-ghost badge-xs", "Shared" }
                        }
                    }
                }
            }
        }
    }
}

#[derive(Props, Clone, PartialEq)]
struct PosterCollageProps {
    poster_paths: Vec<String>,
}

/// Visually composes the card's hero figure. With four+ posters we
/// render a 2x2 mini-grid; fewer fill in placeholder slots, and zero
/// posters falls back to a single illustration. Smart collections come
/// through here with an empty `poster_paths` (engine not ported) and
/// pick up the empty-state illustration cleanly.
#[component]
fn PosterCollage(props: PosterCollageProps) -> Element {
    let poster_paths = props.poster_paths;

    if poster_paths.is_empty() {
        return rsx! {
            div { class: "w-full h-full flex items-center justify-center text-base-content/30",
                Icon { name: "folder".to_string(), class: "w-12 h-12".to_string() }
            }
        };
    }

    // Pad the list to exactly four cells so the grid is symmetric.
    let mut cells: Vec<Option<String>> = poster_paths
        .into_iter()
        .take(4)
        .map(|p| Some(format!("{TMDB_POSTER_BASE}{p}")))
        .collect();
    while cells.len() < 4 {
        cells.push(None);
    }

    rsx! {
        div { class: "grid grid-cols-2 grid-rows-2 w-full h-full",
            for (idx, cell) in cells.into_iter().enumerate() {
                match cell {
                    Some(url) => rsx! {
                        img {
                            key: "{idx}",
                            src: "{url}",
                            alt: "",
                            class: "w-full h-full object-cover",
                            loading: "lazy",
                        }
                    },
                    None => rsx! {
                        div {
                            key: "{idx}",
                            class: "w-full h-full bg-base-300",
                        }
                    },
                }
            }
        }
    }
}
