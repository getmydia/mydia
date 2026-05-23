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

use crate::components::core::{Button, ButtonSize, ButtonVariant};
use crate::routes::Route;
use crate::server_fns::media::{
    delete_media, get_media_detail, list_media_files, list_media_seasons, toggle_episode_monitored,
    toggle_media_monitored, EpisodeView, MediaDetail, MediaFileSummary, SeasonView,
};

const TMDB_POSTER_BASE: &str = "https://image.tmdb.org/t/p/w342";
const TMDB_BACKDROP_BASE: &str = "https://image.tmdb.org/t/p/w1280";

#[component]
pub fn MediaShow(id: String) -> Element {
    // Reload token bumped after any mutation. Reading it inside the
    // `use_resource` closure makes the resource re-run when the token
    // changes — same pattern as the U23 library-paths page. We use
    // `use_resource` here instead of `use_server_future` because the
    // SSR-baked initial render comes from `use_server_future` below
    // (only run once), and the post-mutation refresh runs client-side.
    let mut reload_token = use_signal(|| 0u64);

    let id_for_fetch = id.clone();
    let detail = use_resource(move || {
        let _ = reload_token.read();
        let id = id_for_fetch.clone();
        async move { get_media_detail(id).await }
    });

    let snapshot = detail.read_unchecked();
    let Some(result) = snapshot.clone() else {
        return rsx! {
            div { class: "flex justify-center py-12",
                span { class: "loading loading-spinner loading-lg" }
            }
        };
    };
    drop(snapshot);

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

    let bump_detail = move |()| {
        let next = *reload_token.read() + 1;
        reload_token.set(next);
    };

    rsx! {
        div { class: "flex flex-col gap-6",
            DetailHeader {
                detail: detail.clone(),
                on_changed: bump_detail,
            }
            if detail.kind == "tv_show" {
                SeasonsPanel { id: detail.id.clone() }
            } else {
                MovieFilesPanel { id: detail.id.clone() }
            }
        }
    }
}

#[component]
fn DetailHeader(detail: MediaDetail, on_changed: EventHandler<()>) -> Element {
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

    let mut working = use_signal(|| false);
    let mut flash: Signal<Option<(bool, String)>> = use_signal(|| None);
    let mut show_delete = use_signal(|| false);

    let detail_id_for_toggle = detail.id.clone();
    let on_toggle_monitor = move |_| {
        let id = detail_id_for_toggle.clone();
        if *working.read() {
            return;
        }
        working.set(true);
        spawn(async move {
            match toggle_media_monitored(id).await {
                Ok(ack) => {
                    flash.set(Some((
                        true,
                        if ack.monitored {
                            "Monitoring enabled".to_owned()
                        } else {
                            "Monitoring disabled".to_owned()
                        },
                    )));
                    on_changed.call(());
                }
                Err(err) => {
                    flash.set(Some((false, format!("Failed to toggle: {err}"))));
                }
            }
            working.set(false);
        });
    };

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
                    if let Some((ok, msg)) = flash.read().clone() {
                        div { class: if ok { "alert alert-success py-2" } else { "alert alert-error py-2" },
                            span { class: "text-sm", "{msg}" }
                        }
                    }
                    div { class: "flex flex-wrap gap-2 pt-1",
                        // The Play button only makes sense for movies
                        // here — episode play happens from the seasons
                        // tree (U25.d follow-up). TV shows surface no
                        // headline Play button; navigate to an episode
                        // row instead.
                        if detail.kind == "movie" {
                            Link {
                                to: Route::Play {
                                    kind: "movie".to_string(),
                                    id: detail.id.clone(),
                                },
                                class: "btn btn-primary btn-sm",
                                "Play"
                            }
                        }
                        Button {
                            variant: if detail.monitored { ButtonVariant::Ghost } else { ButtonVariant::Primary },
                            size: ButtonSize::Sm,
                            disabled: *working.read(),
                            onclick: on_toggle_monitor,
                            if detail.monitored { "Stop monitoring" } else { "Start monitoring" }
                        }
                        Button {
                            variant: ButtonVariant::Error,
                            size: ButtonSize::Sm,
                            disabled: *working.read(),
                            onclick: move |_| show_delete.set(true),
                            "Remove from library"
                        }
                    }
                }
            }
        }
        DeleteMediaModal {
            open: *show_delete.read(),
            title: detail.title.clone(),
            id: detail.id.clone(),
            on_close: move |()| show_delete.set(false),
        }
    }
}

#[component]
fn DeleteMediaModal(open: bool, title: String, id: String, on_close: EventHandler<()>) -> Element {
    let mut deleting = use_signal(|| false);
    let mut error: Signal<Option<String>> = use_signal(|| None);
    let nav = navigator();

    let id_for_delete = id.clone();
    let title_for_msg = title.clone();
    let on_confirm = move |_| {
        if *deleting.read() {
            return;
        }
        deleting.set(true);
        error.set(None);
        let id = id_for_delete.clone();
        let _title = title_for_msg.clone();
        spawn(async move {
            match delete_media(id).await {
                Ok(()) => {
                    // Land on the dashboard rather than `/movies` —
                    // we don't know the type cheaply from this scope
                    // and the dashboard is the canonical "what next"
                    // surface after destructive actions.
                    nav.push(Route::Dashboard {});
                }
                Err(err) => {
                    error.set(Some(err.to_string()));
                    deleting.set(false);
                }
            }
        });
    };

    rsx! {
        dialog {
            class: if open { "modal modal-open" } else { "modal" },
            div { class: "modal-box",
                h3 { class: "text-lg font-bold", "Remove from library?" }
                p { class: "py-3 text-sm",
                    "This removes "
                    span { class: "font-semibold", "{title}" }
                    " from the library. Files on disk are preserved and "
                    "the item will be re-imported on the next scan unless "
                    "you also remove the file."
                }
                if let Some(err) = error.read().clone() {
                    div { class: "alert alert-error my-2",
                        span { "{err}" }
                    }
                }
                div { class: "modal-action",
                    Button {
                        variant: ButtonVariant::Ghost,
                        disabled: *deleting.read(),
                        onclick: move |_| on_close.call(()),
                        "Cancel"
                    }
                    Button {
                        variant: ButtonVariant::Error,
                        disabled: *deleting.read(),
                        onclick: on_confirm,
                        if *deleting.read() { "Removing…" } else { "Remove" }
                    }
                }
            }
            form {
                method: "dialog",
                class: "modal-backdrop",
                button {
                    r#type: "submit",
                    onclick: move |_| on_close.call(()),
                    "close"
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
    // Same reload-on-token pattern as MediaShow — episode monitor
    // toggles bump the token so the seasons tree picks up the new
    // state without a full page reload.
    let mut reload_token = use_signal(|| 0u64);
    let id_for_fetch = id.clone();
    let seasons = use_resource(move || {
        let _ = reload_token.read();
        let id = id_for_fetch.clone();
        async move { list_media_seasons(id).await }
    });

    let snapshot = seasons.read_unchecked();
    let Some(result) = snapshot.clone() else {
        return rsx! {
            div { class: "card bg-base-100 shadow-md",
                div { class: "card-body",
                    span { class: "loading loading-dots loading-sm" }
                }
            }
        };
    };
    drop(snapshot);

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

    let on_episode_changed = move |()| {
        let next = *reload_token.read() + 1;
        reload_token.set(next);
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
                                on_episode_changed: on_episode_changed,
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
    on_episode_changed: EventHandler<()>,
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
                        EpisodeRow {
                            episode: episode.clone(),
                            on_changed: on_episode_changed,
                        }
                    }
                }
            }
        }
    }
}

#[component]
fn EpisodeRow(episode: EpisodeView, on_changed: EventHandler<()>) -> Element {
    let label = match (episode.season_number, episode.episode_number) {
        (Some(s), Some(e)) => format!("S{s:02}E{e:02}"),
        (None, Some(e)) => format!("E{e:02}"),
        _ => "—".to_owned(),
    };
    let title = episode.title.clone().unwrap_or_default();
    let air_date = episode.air_date.clone();
    let has_files = episode.has_files;
    let monitored = episode.monitored;
    let mut working = use_signal(|| false);
    let episode_id = episode.id.clone();

    let on_click_monitor = move |_| {
        if *working.read() {
            return;
        }
        working.set(true);
        let id = episode_id.clone();
        spawn(async move {
            // Best-effort toggle. Failure leaves the row's monitored
            // badge stale until the next page reload; the page will
            // refresh on the bump anyway when it succeeds, so an
            // explicit error toast would be more noise than signal
            // for the routine 1-click case.
            let _ = toggle_episode_monitored(id).await;
            working.set(false);
            on_changed.call(());
        });
    };

    let play_route = Route::Play {
        kind: "episode".to_string(),
        id: episode.id.clone(),
    };

    rsx! {
        div { class: "flex items-center gap-3 px-4 py-2 hover:bg-base-200",
            span { class: "font-mono text-xs opacity-60 w-16", "{label}" }
            span { class: "flex-1 min-w-0 truncate text-sm", "{title}" }
            if !air_date.is_empty() {
                span { class: "text-xs opacity-60", "{air_date}" }
            }
            if has_files {
                Link {
                    to: play_route,
                    class: "btn btn-xs btn-primary",
                    "Play"
                }
            }
            button {
                r#type: "button",
                class: if monitored { "badge badge-outline badge-xs cursor-pointer" } else { "badge badge-ghost badge-xs cursor-pointer" },
                disabled: *working.read(),
                onclick: on_click_monitor,
                if monitored { "Monitored" } else { "Unmonitored" }
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
