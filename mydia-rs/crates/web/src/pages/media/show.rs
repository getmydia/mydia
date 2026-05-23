//! `/media/:id` — media detail page (U25.b).
//!
//! Read-only port of `MydiaWeb.MediaLive.Show`'s "core" surface — the
//! header (poster, backdrop, title, year, overview, genres, rating)
//! plus the file/episode tree below. The Phoenix page is ~3.8k LOC
//! split across a dozen `*_events.ex` files for actions (delete,
//! refresh, monitor toggle, manual search, …); U25.b lands the read
//! path and U25.c layers the action buttons on top.
//!
//! For TV shows the seasons list expands the highest-numbered season
//! by default to match Phoenix's `expanded_seasons` mount logic
//! (`lib/mydia_web/live/media_live/show.ex:42-57`). Toggling a season
//! is purely client-side — no server fn required since the data is
//! already loaded into the page state.

use std::collections::HashSet;

use dioxus::prelude::*;

use crate::server_fns::media::{
    get_media_detail, list_media_files, list_media_seasons, EpisodeView, MediaDetail,
    MediaFileSummary, SeasonView,
};

const TMDB_POSTER_BASE: &str = "https://image.tmdb.org/t/p/w342";
const TMDB_BACKDROP_BASE: &str = "https://image.tmdb.org/t/p/w1280";

#[component]
pub fn MediaShow(id: String) -> Element {
    // Resource keyed on id — fetched server-side so SSR ships the
    // detail HTML on the first response. `use_server_future` is
    // required (not `use_resource`) because the page renders nothing
    // useful before the detail loads, and `use_resource` does not
    // suspend during SSR. The closure is FnMut so we clone-per-call
    // rather than moving the captured String once.
    let id_for_fetch = id.clone();
    let detail = use_server_future(move || {
        let id = id_for_fetch.clone();
        async move { get_media_detail(id).await }
    })?;

    let snapshot = detail.read_unchecked().clone();
    let Some(result) = snapshot else {
        return rsx! {
            div { class: "flex justify-center py-12",
                span { class: "loading loading-spinner loading-lg" }
            }
        };
    };

    let detail = match result {
        Ok(d) => d,
        Err(err) => {
            return rsx! {
                div { class: "alert alert-error",
                    span { "Failed to load media: {err}" }
                }
            };
        }
    };

    rsx! {
        div { class: "flex flex-col gap-6",
            DetailHeader { detail: detail.clone() }
            if detail.kind == "tv_show" {
                SeasonsPanel { id: detail.id.clone() }
            } else {
                MovieFilesPanel { id: detail.id.clone() }
            }
        }
    }
}

#[component]
fn DetailHeader(detail: MediaDetail) -> Element {
    let backdrop_url = detail
        .backdrop_path
        .as_deref()
        .map(|p| format!("{TMDB_BACKDROP_BASE}{p}"));
    let poster_url = detail
        .poster_path
        .as_deref()
        .map(|p| format!("{TMDB_POSTER_BASE}{p}"));
    let year_label = detail.year.map(|y| format!("{y}")).unwrap_or_default();
    let runtime_label = detail
        .runtime
        .map(|r| format!("{r} min"))
        .unwrap_or_default();
    let rating_label = detail.rating.map(|r| format!("★ {r:.1}"));

    rsx! {
        div { class: "card bg-base-100 shadow-lg overflow-hidden",
            if let Some(url) = backdrop_url {
                div {
                    class: "h-48 sm:h-64 bg-cover bg-center bg-base-300",
                    style: "background-image: linear-gradient(to bottom, rgba(0,0,0,0.2), rgba(0,0,0,0.7)), url('{url}')",
                }
            } else {
                div { class: "h-12 bg-base-300" }
            }
            div { class: "card-body flex flex-col md:flex-row gap-6",
                div { class: "shrink-0 -mt-20 md:-mt-32 mx-auto md:mx-0",
                    if let Some(url) = poster_url {
                        img {
                            src: "{url}",
                            alt: "{detail.title}",
                            class: "w-40 md:w-56 rounded-lg shadow-xl bg-base-300",
                            loading: "lazy",
                        }
                    } else {
                        div { class: "w-40 md:w-56 aspect-[2/3] rounded-lg shadow-xl bg-base-300 flex items-center justify-center text-base-content/40",
                            "No poster"
                        }
                    }
                }
                div { class: "flex flex-col gap-3 flex-1 min-w-0",
                    div {
                        h1 { class: "text-3xl font-bold tracking-tight", "{detail.title}" }
                        if let Some(original) = detail.original_title.as_ref() {
                            if original.as_str() != detail.title.as_str() {
                                p { class: "text-sm opacity-60 italic", "{original}" }
                            }
                        }
                    }
                    div { class: "flex items-center gap-3 flex-wrap text-sm",
                        if !year_label.is_empty() {
                            span { "{year_label}" }
                        }
                        if !runtime_label.is_empty() {
                            span { class: "opacity-60", "·" }
                            span { "{runtime_label}" }
                        }
                        if let Some(rating) = rating_label.as_ref() {
                            span { class: "opacity-60", "·" }
                            span { "{rating}" }
                        }
                        if detail.monitored {
                            span { class: "badge badge-success badge-sm", "Monitored" }
                        } else {
                            span { class: "badge badge-ghost badge-sm", "Unmonitored" }
                        }
                    }
                    if !detail.genres.is_empty() {
                        div { class: "flex flex-wrap gap-1",
                            for genre in detail.genres.iter() {
                                span { class: "badge badge-outline badge-sm", "{genre}" }
                            }
                        }
                    }
                    if let Some(overview) = detail.overview.as_ref() {
                        p { class: "text-sm leading-relaxed", "{overview}" }
                    }
                    div { class: "flex flex-wrap gap-3 text-xs opacity-60",
                        if let Some(tmdb) = detail.tmdb_id {
                            span { "TMDB: {tmdb}" }
                        }
                        if let Some(tvdb) = detail.tvdb_id {
                            span { "TVDB: {tvdb}" }
                        }
                        if let Some(imdb) = detail.imdb_id.as_ref() {
                            span { "IMDB: {imdb}" }
                        }
                    }
                }
            }
        }
    }
}

#[component]
fn MovieFilesPanel(id: String) -> Element {
    let id_for_fetch = id.clone();
    let files = use_server_future(move || {
        let id = id_for_fetch.clone();
        async move { list_media_files(id).await }
    })?;

    let snapshot = files.read_unchecked().clone();
    let Some(result) = snapshot else {
        return rsx! {
            div { class: "card bg-base-100 shadow-md",
                div { class: "card-body",
                    span { class: "loading loading-dots loading-sm" }
                }
            }
        };
    };

    let files = match result {
        Ok(f) => f,
        Err(err) => {
            return rsx! {
                div { class: "alert alert-error",
                    span { "Failed to load files: {err}" }
                }
            };
        }
    };

    rsx! {
        div { class: "card bg-base-100 shadow-md",
            div { class: "card-body",
                h2 { class: "card-title text-lg", "Files" }
                if files.is_empty() {
                    div { class: "alert alert-info",
                        span { "No files available locally yet." }
                    }
                } else {
                    div { class: "overflow-x-auto",
                        table { class: "table table-zebra",
                            thead {
                                tr {
                                    th { "File" }
                                    th { "Resolution" }
                                    th { "Codec" }
                                    th { "Audio" }
                                    th { "Size" }
                                }
                            }
                            tbody {
                                for file in files.iter() {
                                    MovieFileRow { file: file.clone() }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

#[component]
fn MovieFileRow(file: MediaFileSummary) -> Element {
    rsx! {
        tr {
            td { class: "font-mono text-xs", "{file.filename}" }
            td { "{file.resolution.as_deref().unwrap_or(\"—\")}" }
            td { "{file.codec.as_deref().unwrap_or(\"—\")}" }
            td { "{file.audio_codec.as_deref().unwrap_or(\"—\")}" }
            td { "{format_size(file.size)}" }
        }
    }
}

#[component]
fn SeasonsPanel(id: String) -> Element {
    let id_for_fetch = id.clone();
    let seasons = use_server_future(move || {
        let id = id_for_fetch.clone();
        async move { list_media_seasons(id).await }
    })?;

    let snapshot = seasons.read_unchecked().clone();
    let Some(result) = snapshot else {
        return rsx! {
            div { class: "card bg-base-100 shadow-md",
                div { class: "card-body",
                    span { class: "loading loading-dots loading-sm" }
                }
            }
        };
    };

    let seasons = match result {
        Ok(s) => s,
        Err(err) => {
            return rsx! {
                div { class: "alert alert-error",
                    span { "Failed to load seasons: {err}" }
                }
            };
        }
    };

    // Default-expanded set = the highest season number. Mirrors
    // `expanded_seasons` mount logic at media_live/show.ex:42-57.
    let initial_expanded: HashSet<i32> =
        seasons
            .iter()
            .map(|s| s.season_number)
            .max()
            .map_or_else(HashSet::new, |n| {
                let mut set = HashSet::new();
                set.insert(n);
                set
            });
    let expanded = use_signal(|| initial_expanded);

    rsx! {
        div { class: "card bg-base-100 shadow-md",
            div { class: "card-body",
                h2 { class: "card-title text-lg", "Seasons" }
                if seasons.is_empty() {
                    div { class: "alert alert-info",
                        span { "No episodes loaded yet." }
                    }
                } else {
                    div { class: "flex flex-col gap-3",
                        for season in seasons.iter() {
                            SeasonRow {
                                season: season.clone(),
                                is_expanded: expanded.read().contains(&season.season_number),
                                on_toggle: {
                                    let mut expanded = expanded;
                                    let n = season.season_number;
                                    move |_| {
                                        let mut next = expanded.read().clone();
                                        if next.contains(&n) {
                                            next.remove(&n);
                                        } else {
                                            next.insert(n);
                                        }
                                        expanded.set(next);
                                    }
                                },
                            }
                        }
                    }
                }
            }
        }
    }
}

#[component]
fn SeasonRow(
    season: SeasonView,
    is_expanded: bool,
    on_toggle: EventHandler<MouseEvent>,
) -> Element {
    let season_label = if season.season_number == 0 {
        "Specials".to_owned()
    } else {
        format!("Season {}", season.season_number)
    };

    rsx! {
        div { class: "border border-base-300 rounded-lg",
            button {
                r#type: "button",
                class: "w-full flex items-center justify-between px-4 py-3 hover:bg-base-200 transition-colors text-left",
                onclick: move |evt| on_toggle.call(evt),
                div { class: "flex items-center gap-3",
                    span { class: "font-semibold", "{season_label}" }
                    span { class: "text-xs opacity-60",
                        "{season.downloaded_count}/{season.episode_count} episodes"
                    }
                }
                span { class: "text-xs opacity-60",
                    if is_expanded { "▾" } else { "▸" }
                }
            }
            if is_expanded {
                div { class: "border-t border-base-300",
                    for episode in season.episodes.iter() {
                        EpisodeRow { episode: episode.clone() }
                    }
                }
            }
        }
    }
}

#[component]
fn EpisodeRow(episode: EpisodeView) -> Element {
    let label = match (episode.season_number, episode.episode_number) {
        (Some(s), Some(e)) => format!("S{s:02}E{e:02}"),
        (None, Some(e)) => format!("E{e:02}"),
        _ => "—".to_owned(),
    };
    let title = episode.title.unwrap_or_default();

    rsx! {
        div { class: "flex items-center gap-3 px-4 py-2 hover:bg-base-200",
            span { class: "font-mono text-xs opacity-60 w-16", "{label}" }
            span { class: "flex-1 min-w-0 truncate text-sm", "{title}" }
            if !episode.air_date.is_empty() {
                span { class: "text-xs opacity-60", "{episode.air_date}" }
            }
            if episode.has_files {
                span { class: "badge badge-success badge-xs", "Local" }
            }
            if !episode.monitored {
                span { class: "badge badge-ghost badge-xs", "Unmonitored" }
            }
        }
    }
}

fn format_size(bytes: Option<i64>) -> String {
    // Mirror of `MydiaWeb.MediaLive.Index.format_file_size/1`. SI-ish
    // units (TB / GB / MB / KB / B) with 2-decimal rounding.
    let Some(b) = bytes else {
        return "—".to_owned();
    };
    let b_f = b as f64;
    if b >= 1_099_511_627_776 {
        format!("{:.2} TB", b_f / 1_099_511_627_776.0)
    } else if b >= 1_073_741_824 {
        format!("{:.2} GB", b_f / 1_073_741_824.0)
    } else if b >= 1_048_576 {
        format!("{:.2} MB", b_f / 1_048_576.0)
    } else if b >= 1024 {
        format!("{:.2} KB", b_f / 1024.0)
    } else {
        format!("{b} B")
    }
}
