//! Reusable media grid components — card, list row, and placeholder.
//!
//! Used by `/movies` and `/tv` (U25.a) and the detail-page header
//! (U25.b once the show route lands). Keeps poster URL construction
//! in one place so the TMDB size segment can be tuned without hunting
//! through every page.

use dioxus::prelude::*;

use crate::components::core::{Icon, ProgressBar, ProgressVariant};
use crate::routes::Route;
use crate::server_fns::media::MediaListItem;

/// Prefix for TMDB poster paths. Matches the `w342` size segment
/// `MydiaWeb.MediaHelpers.poster_url/1` uses; bump or vary later if
/// the grid density changes.
const TMDB_POSTER_BASE: &str = "https://image.tmdb.org/t/p/w342";

#[derive(Props, Clone, PartialEq)]
pub struct MediaCardProps {
    pub item: MediaListItem,
    /// When `true`, render the selection checkbox overlay. Selection
    /// affordance is shown in selection-mode regardless of whether
    /// this card is currently selected.
    #[props(default)]
    pub selection_mode: bool,
    #[props(default)]
    pub selected: bool,
    /// Click handler invoked when the card is clicked in selection
    /// mode. The card itself stops navigation in that case so the
    /// parent can toggle selection state.
    #[props(default)]
    pub on_select: Option<EventHandler<MouseEvent>>,
    /// Watched-episodes progress for TV shows. None for movies and
    /// for shows where the data isn't available yet.
    // TODO(graphql): expose watched_episodes / total_episodes on
    // `MediaListItem` so the progress bar populates for TV cards.
    #[props(default)]
    pub progress: Option<f32>,
    /// Display string for the quality badge (e.g. `"1080p"`). None
    /// hides the badge.
    // TODO(graphql): expose `quality_tag` on `MediaListItem`.
    #[props(default)]
    pub quality_tag: Option<String>,
}

#[component]
pub fn MediaCard(props: MediaCardProps) -> Element {
    let item = props.item;
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

    let selection_mode = props.selection_mode;
    let selected = props.selected;
    let on_select = props.on_select;
    let quality_tag = props.quality_tag;
    let progress = props.progress;

    // In selection mode the card swallows clicks and forwards them to
    // `on_select` so the parent can toggle selection state. Otherwise
    // the inner `Link` navigates as usual.
    let on_card_click = move |evt: MouseEvent| {
        if selection_mode {
            if let Some(handler) = on_select.as_ref() {
                handler.call(evt);
            }
        }
    };

    rsx! {
        div {
            class: "relative group transition-all duration-200 hover:scale-[1.02]",
            onclick: on_card_click,

            // Selection checkbox overlay — only rendered in selection mode.
            if selection_mode {
                div { class: "absolute top-2 left-2 z-20 pointer-events-none",
                    input {
                        r#type: "checkbox",
                        class: "checkbox checkbox-primary checkbox-sm bg-base-100/80 backdrop-blur",
                        checked: selected,
                    }
                }
            }

            // Quality badge — top-right when present.
            if let Some(quality) = quality_tag.as_ref() {
                div { class: "absolute top-2 right-2 z-10",
                    span { class: "badge badge-primary badge-sm shadow-md", "{quality}" }
                }
            }

            div {
                class: "card card-compact bg-base-100 shadow-md overflow-hidden hover:shadow-2xl transition-shadow",

                // The Link wraps the visual portion of the card; in
                // selection mode the outer div's `onclick` already ran
                // and propagation here still triggers nav unless we
                // hide the link entirely.
                if selection_mode {
                    // Render the same chrome without a navigation link.
                    {render_card_body(
                        poster_url.clone(),
                        item.title.clone(),
                        year_label.clone(),
                        item.has_files,
                        item.monitored,
                        progress,
                    )}
                } else {
                    Link {
                        to: target,
                        class: "block",
                        {render_card_body(
                            poster_url.clone(),
                            item.title.clone(),
                            year_label.clone(),
                            item.has_files,
                            item.monitored,
                            progress,
                        )}
                    }
                }
            }
        }
    }
}

#[allow(clippy::needless_pass_by_value)]
fn render_card_body(
    poster_url: Option<String>,
    title: String,
    year_label: String,
    has_files: bool,
    monitored: bool,
    progress: Option<f32>,
) -> Element {
    rsx! {
        figure { class: "aspect-[2/3] bg-base-300 relative overflow-hidden",
            if let Some(url) = poster_url {
                img {
                    src: "{url}",
                    alt: "{title}",
                    class: "w-full h-full object-cover group-hover:scale-105 transition-transform duration-300",
                    loading: "lazy",
                }
            } else {
                div { class: "w-full h-full flex items-center justify-center text-base-content/40 text-xs",
                    "No poster"
                }
            }
            // Watched-episodes progress bar pinned to the bottom of
            // the poster. Only rendered when the page passes a value.
            if let Some(pct) = progress {
                div { class: "absolute bottom-0 left-0 right-0 px-1 pb-1",
                    ProgressBar {
                        value: pct,
                        variant: ProgressVariant::Primary,
                        class: "w-full h-1".to_string(),
                    }
                }
            }
        }
        div { class: "card-body",
            h3 { class: "card-title text-sm leading-snug line-clamp-2", "{title}" }
            div { class: "flex items-center justify-between text-xs opacity-70",
                span { "{year_label}" }
                div { class: "flex gap-1",
                    if has_files {
                        span { class: "badge badge-success badge-xs", "Local" }
                    }
                    if !monitored {
                        span { class: "badge badge-ghost badge-xs", "Unmonitored" }
                    }
                }
            }
        }
    }
}

#[derive(Props, Clone, PartialEq)]
pub struct MediaListRowProps {
    pub item: MediaListItem,
    #[props(default)]
    pub selection_mode: bool,
    #[props(default)]
    pub selected: bool,
    #[props(default)]
    pub on_select: Option<EventHandler<MouseEvent>>,
    // TODO(graphql): expose `quality_tag` on `MediaListItem`.
    #[props(default)]
    pub quality_tag: Option<String>,
}

/// Single horizontal row used by the list view. Mirrors
/// `library_components.ex`'s `library_list_row` shape — checkbox,
/// small poster, title, year, status, quality columns.
#[component]
pub fn MediaListRow(props: MediaListRowProps) -> Element {
    let item = props.item;
    let poster_url = item
        .poster_path
        .as_deref()
        .map(|p| format!("{TMDB_POSTER_BASE}{p}"));
    let year_label = item
        .year
        .map_or_else(|| "—".to_string(), |y| format!("{y}"));
    let target = Route::MediaShow {
        id: item.id.clone(),
    };
    let selection_mode = props.selection_mode;
    let selected = props.selected;
    let on_select = props.on_select;
    let quality_tag = props.quality_tag;

    let on_row_click = move |evt: MouseEvent| {
        if selection_mode {
            if let Some(handler) = on_select.as_ref() {
                handler.call(evt);
            }
        }
    };

    rsx! {
        div {
            class: "flex items-center px-4 py-3 hover:bg-base-200/50 border-b border-base-200 last:border-b-0 transition-colors cursor-pointer",
            onclick: on_row_click,

            // Checkbox column (selection mode only)
            if selection_mode {
                div { class: "w-10 flex-shrink-0",
                    input {
                        r#type: "checkbox",
                        class: "checkbox checkbox-primary checkbox-sm",
                        checked: selected,
                    }
                }
            } else {
                div { class: "w-10 flex-shrink-0" }
            }

            // Poster column
            div { class: "w-14 flex-shrink-0",
                if selection_mode {
                    if let Some(url) = poster_url.clone() {
                        img {
                            src: "{url}",
                            alt: "{item.title}",
                            loading: "lazy",
                            class: "w-10 h-14 rounded shadow-sm object-cover bg-base-300",
                        }
                    } else {
                        div { class: "w-10 h-14 rounded shadow-sm bg-base-300 flex items-center justify-center",
                            Icon { name: "photo".to_string(), class: "w-4 h-4 opacity-40".to_string() }
                        }
                    }
                } else {
                    Link { to: target.clone(), class: "block w-10",
                        if let Some(url) = poster_url.clone() {
                            img {
                                src: "{url}",
                                alt: "{item.title}",
                                loading: "lazy",
                                class: "w-10 h-14 rounded shadow-sm object-cover bg-base-300",
                            }
                        } else {
                            div { class: "w-10 h-14 rounded shadow-sm bg-base-300 flex items-center justify-center",
                                Icon { name: "photo".to_string(), class: "w-4 h-4 opacity-40".to_string() }
                            }
                        }
                    }
                }
            }

            // Title column
            div { class: "flex-1 min-w-0 pr-4",
                if selection_mode {
                    span { class: "font-medium line-clamp-1", "{item.title}" }
                } else {
                    Link {
                        to: target.clone(),
                        class: "font-medium hover:text-primary transition-colors line-clamp-1",
                        "{item.title}"
                    }
                }
            }

            // Year column
            div { class: "w-20 hidden md:block text-center text-base-content/70 flex-shrink-0",
                "{year_label}"
            }

            // Status column
            div { class: "w-28 hidden lg:block flex-shrink-0",
                div { class: "flex items-center gap-1",
                    if item.monitored {
                        span { class: "badge badge-primary badge-sm", "Monitored" }
                    } else {
                        span { class: "badge badge-ghost badge-sm", "Unmonitored" }
                    }
                    if item.has_files {
                        span { class: "badge badge-success badge-sm gap-1",
                            Icon { name: "check".to_string(), class: "w-3 h-3".to_string() }
                        }
                    }
                }
            }

            // Quality column
            div { class: "w-20 hidden lg:block text-center flex-shrink-0",
                if let Some(quality) = quality_tag.as_ref() {
                    span { class: "badge badge-primary badge-sm", "{quality}" }
                } else {
                    span { class: "text-base-content/40", "—" }
                }
            }
        }
    }
}
