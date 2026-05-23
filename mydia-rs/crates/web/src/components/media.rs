//! Reusable media grid components — card and placeholder.
//!
//! Used by `/movies` and `/tv` (U25.a) and the detail-page header
//! (U25.b once the show route lands). Keeps poster URL construction
//! in one place so the TMDB size segment can be tuned without hunting
//! through every page.

use dioxus::prelude::*;

use crate::routes::Route;
use crate::server_fns::media::MediaListItem;

/// Prefix for TMDB poster paths. Matches the `w342` size segment
/// `MydiaWeb.MediaHelpers.poster_url/1` uses; bump or vary later if
/// the grid density changes.
const TMDB_POSTER_BASE: &str = "https://image.tmdb.org/t/p/w342";

#[component]
pub fn MediaCard(item: MediaListItem) -> Element {
    let poster_url = item
        .poster_path
        .as_deref()
        .map(|p| format!("{TMDB_POSTER_BASE}{p}"));
    let year_label = item.year.map(|y| format!("{y}")).unwrap_or_default();

    // Route to /media/:id rather than a kind-specific route; the show
    // page (U25.b) discriminates internally by querying the row's type.
    let target = Route::MediaShow {
        id: item.id.clone(),
    };

    rsx! {
        Link {
            to: target,
            class: "card card-compact bg-base-100 shadow-md overflow-hidden hover:shadow-lg transition-shadow",
            if let Some(url) = poster_url {
                figure { class: "aspect-[2/3] bg-base-300",
                    img {
                        src: "{url}",
                        alt: "{item.title}",
                        class: "w-full h-full object-cover",
                        loading: "lazy",
                    }
                }
            } else {
                div { class: "aspect-[2/3] bg-base-300 flex items-center justify-center text-base-content/40 text-xs",
                    "No poster"
                }
            }
            div { class: "card-body",
                h3 { class: "card-title text-sm leading-snug line-clamp-2", "{item.title}" }
                div { class: "flex items-center justify-between text-xs opacity-70",
                    span { "{year_label}" }
                    div { class: "flex gap-1",
                        if item.has_files {
                            span { class: "badge badge-success badge-xs", "Local" }
                        }
                        if !item.monitored {
                            span { class: "badge badge-ghost badge-xs", "Unmonitored" }
                        }
                    }
                }
            }
        }
    }
}
