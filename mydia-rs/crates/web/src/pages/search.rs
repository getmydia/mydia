//! `/search` — library search across movies + TV (U26).
//!
//! Search-as-you-type input bound to a server fn that returns up to
//! [`crate::server_fns::search::SEARCH_LIMIT`] matches ranked by
//! relevance. Music / books / adult are intentionally excluded; the
//! Rust backend drops those surfaces.
//!
//! The Phoenix `SearchLive.Index` is a torrent-indexer search page,
//! not a library-search page. The two surfaces share a route name
//! and a search box and that's about it. The library search wins
//! the `/search` route in the Rust port because "find a thing in my
//! library" is the higher-traffic flow; the indexer search comes back
//! under a different route (or doesn't, depending on how the broader
//! port lands).

use dioxus::prelude::*;

use crate::components::admin::AdminPageHeader;
use crate::components::core::Icon;
use crate::routes::Route;
use crate::server_fns::search::{search_library, SearchQuery, SearchResultItem};

const TMDB_POSTER_BASE: &str = "https://image.tmdb.org/t/p/w185";

#[component]
pub fn Search() -> Element {
    let query = use_signal(String::new);

    // The Phoenix `phx-debounce="300"` shape isn't a 1:1 in Dioxus —
    // `use_resource` already debounces by deduping identical resource
    // values, and re-fetches on every signal change. We additionally
    // gate the server call on `len() >= 2` server-side so a single
    // keystroke doesn't fan out into a query. A real throttle (cancel
    // in-flight on keystroke) is a follow-up; the cost of fetching
    // again on each keypress against a local SQLite DB is negligible.
    let q_clone = query;
    let results = use_resource(move || async move {
        let q = q_clone.read().clone();
        search_library(SearchQuery { q }).await
    });

    let current_q = query.read().clone();
    let snapshot = results.read_unchecked();
    let load_error: Option<String> = match snapshot.as_ref() {
        Some(Err(err)) => Some(err.to_string()),
        _ => None,
    };
    let rows: Vec<SearchResultItem> = match snapshot.as_ref() {
        Some(Ok(rows)) => rows.clone(),
        _ => Vec::new(),
    };
    let is_loading = snapshot.is_none();
    drop(snapshot);

    let trimmed_len = current_q.trim().chars().count();

    rsx! {
        div { class: "max-w-3xl mx-auto",
            AdminPageHeader {
                title: "Search".to_string(),
                subtitle: Some("Find movies and TV shows in your library.".to_string()),
            }

            SearchInput { query: query }

            if let Some(err) = load_error {
                div { class: "alert alert-error mt-4",
                    span { "Search failed: {err}" }
                }
            } else if trimmed_len < 2 {
                InitialState {}
            } else if is_loading && rows.is_empty() {
                div { class: "flex justify-center py-12",
                    span { class: "loading loading-spinner loading-md" }
                }
            } else if rows.is_empty() {
                NoResultsState { query: current_q }
            } else {
                ResultsList { rows: rows }
            }
        }
    }
}

#[derive(Props, Clone, PartialEq)]
struct SearchInputProps {
    query: Signal<String>,
}

#[component]
fn SearchInput(props: SearchInputProps) -> Element {
    let mut query = props.query;
    let current = query.read().clone();

    let on_input = move |evt: Event<FormData>| {
        query.set(evt.value());
    };

    let on_clear = move |_| {
        query.set(String::new());
    };

    let show_clear = !current.is_empty();

    rsx! {
        label { class: "input input-lg input-bordered w-full flex items-center gap-3",
            Icon { name: "magnifying-glass".to_string(), class: "w-5 h-5 text-base-content/50 flex-shrink-0".to_string() }
            input {
                id: "search-input",
                r#type: "search",
                name: "q",
                class: "grow bg-transparent border-none focus:outline-none text-lg min-w-0",
                placeholder: "Search your library…",
                value: "{current}",
                oninput: on_input,
                autocomplete: "off",
                autofocus: true,
            }
            if show_clear {
                button {
                    id: "search-clear",
                    r#type: "button",
                    class: "btn btn-ghost btn-sm btn-circle flex-shrink-0",
                    onclick: on_clear,
                    Icon { name: "x-mark".to_string(), class: "w-5 h-5".to_string() }
                }
            }
        }
    }
}

#[component]
fn InitialState() -> Element {
    rsx! {
        div { id: "search-initial",
            class: "flex flex-col items-center justify-center py-16 text-base-content/50",
            Icon { name: "magnifying-glass".to_string(), class: "w-16 h-16 mb-4 opacity-30".to_string() }
            p { class: "font-medium", "Search your library" }
            p { class: "text-sm", "Type at least 2 characters to search" }
        }
    }
}

#[derive(Props, Clone, PartialEq)]
struct NoResultsStateProps {
    query: String,
}

#[component]
fn NoResultsState(props: NoResultsStateProps) -> Element {
    rsx! {
        div { id: "search-no-results",
            class: "flex flex-col items-center justify-center py-16 text-base-content/50",
            Icon { name: "magnifying-glass".to_string(), class: "w-16 h-16 mb-4 opacity-30".to_string() }
            p { class: "font-medium", "No results for \"{props.query}\"" }
            p { class: "text-sm", "Try a shorter or different search term." }
        }
    }
}

#[derive(Props, Clone, PartialEq)]
struct ResultsListProps {
    rows: Vec<SearchResultItem>,
}

#[component]
fn ResultsList(props: ResultsListProps) -> Element {
    let rows = props.rows;
    rsx! {
        ul { id: "search-results",
            class: "divide-y divide-base-200 bg-base-100 rounded-box shadow",
            for row in rows {
                ResultRow { key: "{row.id}", row: row }
            }
        }
    }
}

#[derive(Props, Clone, PartialEq)]
struct ResultRowProps {
    row: SearchResultItem,
}

#[component]
fn ResultRow(props: ResultRowProps) -> Element {
    let row = props.row;
    let poster_url = row
        .poster_path
        .as_deref()
        .map(|p| format!("{TMDB_POSTER_BASE}{p}"));
    let target = Route::MediaShow { id: row.id.clone() };

    rsx! {
        li {
            Link { to: target,
                class: "flex items-center gap-3 p-3 hover:bg-base-200 transition-colors",
                div { class: "w-12 h-18 flex-shrink-0 rounded overflow-hidden bg-base-300",
                    if let Some(url) = poster_url {
                        img {
                            src: "{url}",
                            alt: "",
                            class: "w-full h-full object-cover",
                            loading: "lazy",
                        }
                    } else {
                        div { class: "w-full h-full flex items-center justify-center",
                            Icon { name: "film".to_string(), class: "w-6 h-6 text-base-content/20".to_string() }
                        }
                    }
                }
                div { class: "flex-1 min-w-0",
                    h4 { class: "font-medium truncate", "{row.title}" }
                    div { class: "text-sm text-base-content/60", "{row.subtitle}" }
                }
                Icon { name: "chevron-up".to_string(), class: "w-4 h-4 text-base-content/30 rotate-90".to_string() }
            }
        }
    }
}
