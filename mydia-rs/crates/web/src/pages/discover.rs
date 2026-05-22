//! `/discover` — browse trending and curated TMDB lists (U24.f).
//!
//! Minimal port of `MydiaWeb.DiscoverLive.Index`. The Phoenix surface
//! accepts a full filter set (genre, year, original-language, sort,
//! min-rating); this U24.f shell keeps it to the four controls the
//! relay client wraps today:
//!
//!   - media type toggle (movies vs tv)
//!   - category dropdown (`trending` / `popular` / `upcoming` / `now_playing`
//!     for movies; `trending` / `popular` / `on_the_air` / `airing_today`
//!     for tv)
//!   - language picker (~20 codes — the same list Phoenix ships)
//!   - paginated grid (one page at a time; "previous" + "next")
//!
//! The genre filter, sort selector, and infinite-scroll list belong
//! to a follow-up. The page works end-to-end against the live relay
//! today.

use dioxus::prelude::*;

use crate::components::core::{Button, ButtonVariant};
use crate::server_fns::discover::{discover, DiscoverItem, DiscoverPage, DiscoverQuery};

/// Curated category options surfaced in the dropdown. Two distinct
/// lists per media type because TMDB exposes different endpoints
/// (`/upcoming` only for movies, `/on_the_air` only for tv).
const MOVIE_CATEGORIES: &[(&str, &str)] = &[
    ("trending", "Trending"),
    ("popular", "Popular"),
    ("upcoming", "Upcoming"),
    ("now_playing", "Now playing"),
];
const TV_CATEGORIES: &[(&str, &str)] = &[
    ("trending", "Trending"),
    ("popular", "Popular"),
    ("on_the_air", "On the air"),
    ("airing_today", "Airing today"),
];

/// Locale options — same set the Phoenix `DiscoverLive` ships.
const LANGUAGES: &[(&str, &str)] = &[
    ("en", "English"),
    ("ja", "Japanese"),
    ("ko", "Korean"),
    ("es", "Spanish"),
    ("fr", "French"),
    ("de", "German"),
    ("it", "Italian"),
    ("pt", "Portuguese"),
    ("zh", "Chinese"),
    ("hi", "Hindi"),
    ("ru", "Russian"),
    ("ar", "Arabic"),
    ("th", "Thai"),
    ("tr", "Turkish"),
    ("pl", "Polish"),
    ("nl", "Dutch"),
    ("sv", "Swedish"),
    ("da", "Danish"),
    ("no", "Norwegian"),
    ("fi", "Finnish"),
];

#[component]
pub fn Discover() -> Element {
    let query = use_signal(DiscoverQuery::default);

    // The page resource re-runs whenever any of the form inputs
    // change (the signal mutation is the trigger). `use_resource` is
    // happy chaining on `query.read().clone()` because DiscoverQuery
    // implements Eq.
    let q_clone = query;
    let page_resource = use_resource(move || async move {
        let q = q_clone.read().clone();
        discover(q).await
    });

    rsx! {
        div { class: "flex flex-col gap-6",
            h1 { class: "text-2xl font-bold tracking-tight", "Discover" }

            DiscoverFilters { query: query }

            DiscoverGrid {
                state: stringify_page(page_resource.read_unchecked().as_ref()),
                go_prev: {
                    let mut q = query;
                    move || {
                        let mut next = q.read().clone();
                        if next.page > 1 {
                            next.page -= 1;
                            q.set(next);
                        }
                    }
                },
                go_next: {
                    let mut q = query;
                    move || {
                        let mut next = q.read().clone();
                        next.page = next.page.saturating_add(1);
                        q.set(next);
                    }
                },
            }
        }
    }
}

fn stringify_page(
    snapshot: Option<&Result<DiscoverPage, dioxus::fullstack::ServerFnError>>,
) -> Option<Result<DiscoverPage, String>> {
    match snapshot {
        None => None,
        Some(Ok(p)) => Some(Ok(p.clone())),
        Some(Err(err)) => Some(Err(err.to_string())),
    }
}

#[component]
fn DiscoverFilters(query: Signal<DiscoverQuery>) -> Element {
    // Match the category options to the active media type — when the
    // operator flips movies <-> tv, the dropdown picks the matching
    // set on next render.
    let media_type = query.read().media_type.clone();
    let categories = if media_type == "tv_show" {
        TV_CATEGORIES
    } else {
        MOVIE_CATEGORIES
    };
    let current_category = query.read().category.clone();
    let current_language = query.read().language.clone();

    let set_media_type = move |evt: Event<FormData>| {
        let value = evt.value();
        let mut next = query.read().clone();
        next.media_type = value;
        // Reset to "trending" when the media type changes — the
        // currently selected category may not exist on the other
        // side (e.g. "upcoming" doesn't exist for tv).
        next.category = "trending".into();
        next.page = 1;
        query.set(next);
    };

    let set_category = move |evt: Event<FormData>| {
        let mut next = query.read().clone();
        next.category = evt.value();
        next.page = 1;
        query.set(next);
    };

    let set_language = move |evt: Event<FormData>| {
        let mut next = query.read().clone();
        next.language = evt.value();
        next.page = 1;
        query.set(next);
    };

    rsx! {
        div { class: "card bg-base-100 shadow-md",
            div { class: "card-body flex flex-col gap-4 md:flex-row md:items-end",
                label { class: "form-control w-full md:w-40",
                    div { class: "label", span { class: "label-text", "Type" } }
                    select {
                        class: "select select-bordered",
                        value: "{media_type}",
                        onchange: set_media_type,
                        option { value: "movie", "Movies" }
                        option { value: "tv_show", "TV shows" }
                    }
                }

                label { class: "form-control w-full md:w-56",
                    div { class: "label", span { class: "label-text", "Category" } }
                    select {
                        class: "select select-bordered",
                        value: "{current_category}",
                        onchange: set_category,
                        for (value, label) in categories.iter() {
                            option { value: *value, "{label}" }
                        }
                    }
                }

                label { class: "form-control w-full md:w-48",
                    div { class: "label", span { class: "label-text", "Language" } }
                    select {
                        class: "select select-bordered",
                        value: "{current_language}",
                        onchange: set_language,
                        for (code, name) in LANGUAGES.iter() {
                            option { value: *code, "{name}" }
                        }
                    }
                }
            }
        }
    }
}

#[component]
fn DiscoverGrid(
    state: Option<Result<DiscoverPage, String>>,
    go_prev: EventHandler<()>,
    go_next: EventHandler<()>,
) -> Element {
    match state {
        None => rsx! {
            div { class: "flex justify-center py-12",
                span { class: "loading loading-spinner loading-lg" }
            }
        },
        Some(Err(err)) => rsx! {
            div { class: "alert alert-error",
                span { "Discover query failed: {err}" }
            }
        },
        Some(Ok(page)) => rsx! {
            div { class: "flex flex-col gap-4",
                if page.items.is_empty() {
                    div { class: "alert alert-info",
                        span { "No results returned by the metadata relay." }
                    }
                } else {
                    div { class: "grid gap-4 grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5",
                        for item in page.items.iter() {
                            DiscoverCard { item: item.clone() }
                        }
                    }
                }

                Pager {
                    page: page.page,
                    total_pages: page.total_pages,
                    go_prev: go_prev,
                    go_next: go_next,
                }
            }
        },
    }
}

#[component]
fn DiscoverCard(item: DiscoverItem) -> Element {
    // TMDB poster URLs require the image base + size segment to
    // render. The metadata-relay returns just the `/abc123.jpg`
    // path; we render through https://image.tmdb.org/t/p/w342 which
    // matches Phoenix's `MydiaWeb.MediaHelpers.tmdb_poster_url/1`
    // shape. The size segment can be made configurable later.
    let poster_url = item
        .poster_path
        .as_deref()
        .map(|p| format!("https://image.tmdb.org/t/p/w342{p}"));
    let year_label = item.year.map(|y| format!("{y}")).unwrap_or_default();
    let rating = item
        .vote_average
        .map(|r| format!("★ {r:.1}"))
        .unwrap_or_default();

    rsx! {
        div { class: "card card-compact bg-base-100 shadow-md overflow-hidden",
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
                div { class: "aspect-[2/3] bg-base-300 flex items-center justify-center text-base-content/40",
                    "No poster"
                }
            }
            div { class: "card-body",
                h3 { class: "card-title text-sm leading-snug line-clamp-2", "{item.title}" }
                div { class: "flex justify-between text-xs opacity-70",
                    span { "{year_label}" }
                    span { "{rating}" }
                }
            }
        }
    }
}

#[component]
fn Pager(
    page: u32,
    total_pages: u32,
    go_prev: EventHandler<()>,
    go_next: EventHandler<()>,
) -> Element {
    rsx! {
        div { class: "flex items-center justify-between mt-2",
            div { class: "text-sm opacity-70",
                "Page {page} of {total_pages}"
            }
            div { class: "flex gap-2",
                Button {
                    variant: ButtonVariant::Outline,
                    disabled: page <= 1,
                    onclick: move |_| go_prev.call(()),
                    "Previous"
                }
                Button {
                    variant: ButtonVariant::Outline,
                    disabled: page >= total_pages,
                    onclick: move |_| go_next.call(()),
                    "Next"
                }
            }
        }
    }
}
