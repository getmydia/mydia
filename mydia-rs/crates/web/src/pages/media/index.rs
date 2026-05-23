//! `/movies` and `/tv` — paginated grid of media items (U25.a).
//!
//! Minimal port of `MydiaWeb.MediaLive.Index`. The Phoenix page carries
//! ~950 LOC of selection mode, batch actions, modals, and real-time
//! scan progress; U25.a establishes the read path (list + filter +
//! search + sort + paginate), and U25.c layers the write surface on
//! top once the show page (U25.b) needs the same actions.

use dioxus::prelude::*;

use crate::components::core::{Button, ButtonVariant};
use crate::components::media::MediaCard;
use crate::server_fns::media::{list_media, MediaListItem, MediaQuery, MediaSort, MonitoredFilter};

const SORT_OPTIONS: &[(&str, &str)] = &[
    ("title_asc", "Title (A–Z)"),
    ("title_desc", "Title (Z–A)"),
    ("year_desc", "Year (newest)"),
    ("year_asc", "Year (oldest)"),
    ("added_desc", "Recently added"),
    ("added_asc", "Oldest added"),
];

#[component]
pub fn Movies() -> Element {
    rsx! { MediaIndex { kind: "movie".to_string(), page_title: "Movies".to_string() } }
}

#[component]
pub fn TvShows() -> Element {
    rsx! { MediaIndex { kind: "tv_show".to_string(), page_title: "TV Shows".to_string() } }
}

#[component]
fn MediaIndex(kind: String, page_title: String) -> Element {
    // The query signal drives the resource — any input change resets
    // pagination back to page 0 by calling `reset_page` so the user
    // never lands on an empty "page 5 of 1" state.
    let mut query = use_signal(|| MediaQuery::new(&kind));

    // Re-fetch whenever the query changes. The resource caches the
    // last good result so the grid doesn't blank between refetches —
    // we render the cached page with a small spinner overlay.
    let mut accumulator: Signal<Vec<MediaListItem>> = use_signal(Vec::new);
    let mut current_total = use_signal(|| 0i64);
    let mut current_has_more = use_signal(|| false);

    let q_clone = query;
    let page_resource = use_resource(move || async move {
        let q = q_clone.read().clone();
        list_media(q).await
    });

    // Stitch incoming pages onto the accumulator. Page 0 replaces;
    // higher pages append. The accumulator pattern mirrors the
    // Phoenix `stream(:media_items, _, reset: true|false)` shape —
    // reset on filter change, append on "load more."
    let q_for_effect = query;
    let resource_clone = page_resource;
    use_effect(move || {
        let snapshot = resource_clone.read_unchecked();
        let Some(Ok(page)) = snapshot.as_ref() else {
            return;
        };
        let page_clone = page.clone();
        let q = q_for_effect.read().clone();
        if q.page == 0 {
            accumulator.set(page_clone.items.clone());
        } else {
            let mut next = accumulator.read().clone();
            next.extend(page_clone.items.iter().cloned());
            accumulator.set(next);
        }
        current_total.set(page_clone.total);
        current_has_more.set(page_clone.has_more);
    });

    let resource_snapshot = page_resource.read_unchecked();
    let is_loading = resource_snapshot.is_none();
    let load_error: Option<String> = match resource_snapshot.as_ref() {
        Some(Err(err)) => Some(err.to_string()),
        _ => None,
    };
    drop(resource_snapshot);

    rsx! {
        div { class: "flex flex-col gap-6",
            div { class: "flex items-baseline justify-between flex-wrap gap-2",
                h1 { class: "text-2xl font-bold tracking-tight", "{page_title}" }
                span { class: "text-sm opacity-60",
                    "{current_total.read()} total"
                }
            }

            MediaFilters { query: query }

            if let Some(err) = load_error {
                div { class: "alert alert-error",
                    span { "Failed to load: {err}" }
                }
            }

            MediaGrid {
                items: accumulator.read().clone(),
                is_loading: is_loading,
            }

            if *current_has_more.read() {
                div { class: "flex justify-center pt-2",
                    Button {
                        variant: ButtonVariant::Outline,
                        disabled: is_loading,
                        onclick: move |_| {
                            let mut next = query.read().clone();
                            next.page = next.page.saturating_add(1);
                            query.set(next);
                        },
                        if is_loading { "Loading…" } else { "Load more" }
                    }
                }
            } else if !accumulator.read().is_empty() {
                div { class: "text-center text-xs opacity-50 pt-2",
                    "End of results"
                }
            }
        }
    }
}

#[component]
fn MediaFilters(query: Signal<MediaQuery>) -> Element {
    let current_search = query.read().search.clone();
    let current_sort = query.read().sort;
    let current_monitored = query.read().monitored;

    let on_search = move |evt: Event<FormData>| {
        let mut next = query.read().clone();
        next.search = evt.value();
        next.page = 0;
        query.set(next);
    };

    let on_sort = move |evt: Event<FormData>| {
        let mut next = query.read().clone();
        next.sort = MediaSort::parse(&evt.value());
        next.page = 0;
        query.set(next);
    };

    let on_monitored = move |evt: Event<FormData>| {
        let mut next = query.read().clone();
        next.monitored = MonitoredFilter::parse(&evt.value());
        next.page = 0;
        query.set(next);
    };

    let monitored_value = match current_monitored {
        MonitoredFilter::All => "all",
        MonitoredFilter::Monitored => "true",
        MonitoredFilter::Unmonitored => "false",
    };

    rsx! {
        div { class: "card bg-base-100 shadow-md",
            div { class: "card-body flex flex-col gap-4 md:flex-row md:items-end",
                label { class: "form-control w-full md:flex-1",
                    div { class: "label", span { class: "label-text", "Search" } }
                    input {
                        r#type: "search",
                        class: "input input-bordered",
                        placeholder: "Title…",
                        value: "{current_search}",
                        oninput: on_search,
                    }
                }

                label { class: "form-control w-full md:w-56",
                    div { class: "label", span { class: "label-text", "Sort" } }
                    select {
                        class: "select select-bordered",
                        value: "{current_sort.as_str()}",
                        onchange: on_sort,
                        for (value, label) in SORT_OPTIONS.iter() {
                            option { value: *value, "{label}" }
                        }
                    }
                }

                label { class: "form-control w-full md:w-48",
                    div { class: "label", span { class: "label-text", "Status" } }
                    select {
                        class: "select select-bordered",
                        value: "{monitored_value}",
                        onchange: on_monitored,
                        option { value: "all", "All" }
                        option { value: "true", "Monitored" }
                        option { value: "false", "Unmonitored" }
                    }
                }
            }
        }
    }
}

#[component]
fn MediaGrid(items: Vec<MediaListItem>, is_loading: bool) -> Element {
    if items.is_empty() && is_loading {
        return rsx! {
            div { class: "flex justify-center py-12",
                span { class: "loading loading-spinner loading-lg" }
            }
        };
    }

    if items.is_empty() {
        return rsx! {
            div { class: "alert alert-info",
                span { "No media items match the current filters." }
            }
        };
    }

    rsx! {
        div { class: "grid gap-4 grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6",
            for item in items.iter() {
                MediaCard { item: item.clone() }
            }
        }
    }
}

#[cfg(not(feature = "server"))]
mod _allow_unused {
    // No-op: ensures the file is exercised even when the server
    // feature is off and `use_resource` futures resolve synchronously
    // with stub data.
}
