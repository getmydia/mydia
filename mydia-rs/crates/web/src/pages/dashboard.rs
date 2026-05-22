//! `/` — the operator's at-a-glance dashboard (U24.e).
//!
//! Replaces the U22 placeholder `Home` page on the `/` route. Mirrors
//! the read-only shape of `MydiaWeb.DashboardLive.Index` — counts +
//! recent + upcoming episodes. Trending titles from the metadata
//! relay, the per-item "add to library" flow, and live download
//! progress are deferred to follow-ups (U24 surface budget; the
//! trending widget alone is a several-hundred-LOC port).
//!
//! Three resources fan out in parallel on mount. Each renders into
//! its own card so a slow query doesn't block the rest of the page.

use dioxus::fullstack::ServerFnError;
use dioxus::prelude::*;

use crate::server_fns::dashboard::{
    dashboard_stats, recent_episodes, upcoming_episodes, DashboardEpisode, DashboardStats,
};

#[component]
pub fn Dashboard() -> Element {
    let stats = use_resource(|| async move { dashboard_stats().await });
    let recent = use_resource(|| async move { recent_episodes().await });
    let upcoming = use_resource(|| async move { upcoming_episodes().await });

    // Dioxus component props need Clone + PartialEq, and ServerFnError
    // isn't PartialEq. Stringify at the boundary so the child sees a
    // plain Result<T, String>.
    let stats_view = match &*stats.read_unchecked() {
        None => None,
        Some(Ok(s)) => Some(Ok(s.clone())),
        Some(Err(err)) => Some(Err(err.to_string())),
    };
    let recent_view = stringify_list(recent.read_unchecked().as_ref());
    let upcoming_view = stringify_list(upcoming.read_unchecked().as_ref());

    rsx! {
        div { class: "flex flex-col gap-6",
            h1 { class: "text-2xl font-bold tracking-tight", "Dashboard" }

            StatStrip { stats: stats_view }

            div { class: "grid gap-6 lg:grid-cols-2",
                EpisodeCard {
                    title: "Recent episodes (last 7 days)".to_string(),
                    empty: "No episodes aired in the last week.".to_string(),
                    state: recent_view,
                }
                EpisodeCard {
                    title: "Upcoming episodes (next 7 days)".to_string(),
                    empty: "No upcoming episodes in the next week.".to_string(),
                    state: upcoming_view,
                }
            }
        }
    }
}

/// Convert the dioxus `use_resource` snapshot into a `Clone` +
/// `PartialEq` shape suitable for passing into a child component.
fn stringify_list(
    snapshot: Option<&Result<Vec<DashboardEpisode>, ServerFnError>>,
) -> Option<Result<Vec<DashboardEpisode>, String>> {
    match snapshot {
        None => None,
        Some(Ok(v)) => Some(Ok(v.clone())),
        Some(Err(err)) => Some(Err(err.to_string())),
    }
}

#[component]
fn StatStrip(stats: Option<Result<DashboardStats, String>>) -> Element {
    rsx! {
        div { class: "stats stats-vertical lg:stats-horizontal shadow w-full",
            match &stats {
                None => rsx! {
                    div { class: "stat",
                        span { class: "loading loading-spinner loading-md" }
                    }
                },
                Some(Err(err)) => rsx! {
                    div { class: "stat",
                        div { class: "text-sm text-error", "Stats unavailable: {err}" }
                    }
                },
                Some(Ok(s)) => rsx! {
                    Stat { label: "Movies".to_string(), value: format_count(s.movie_count) }
                    Stat { label: "TV shows".to_string(), value: format_count(s.tv_show_count) }
                    Stat { label: "Active downloads".to_string(), value: format_count(s.active_downloads_count) }
                    Stat { label: "Total storage".to_string(), value: format_bytes(s.total_storage_bytes) }
                },
            }
        }
    }
}

#[component]
fn Stat(label: String, value: String) -> Element {
    rsx! {
        div { class: "stat",
            div { class: "stat-title", "{label}" }
            div { class: "stat-value text-2xl lg:text-3xl", "{value}" }
        }
    }
}

#[component]
fn EpisodeCard(
    title: String,
    empty: String,
    state: Option<Result<Vec<DashboardEpisode>, String>>,
) -> Element {
    rsx! {
        div { class: "card bg-base-100 shadow-md",
            div { class: "card-body",
                h2 { class: "card-title text-lg", "{title}" }
                match &state {
                    None => rsx! { span { class: "loading loading-spinner loading-md" } },
                    Some(Err(err)) => rsx! {
                        div { class: "alert alert-error", "Couldn't load: {err}" }
                    },
                    Some(Ok(items)) if items.is_empty() => rsx! {
                        div { class: "text-sm opacity-60", "{empty}" }
                    },
                    Some(Ok(items)) => rsx! {
                        ul { class: "divide-y divide-base-content/10",
                            for ep in items.iter() {
                                EpisodeRow { episode: ep.clone() }
                            }
                        }
                    },
                }
            }
        }
    }
}

#[component]
fn EpisodeRow(episode: DashboardEpisode) -> Element {
    let show_title = episode
        .media_item_title
        .clone()
        .unwrap_or_else(|| "Unknown show".to_owned());
    let label = match (episode.season_number, episode.episode_number) {
        (Some(s), Some(e)) => format!("S{s:02}E{e:02}"),
        (Some(s), None) => format!("S{s:02}"),
        _ => String::new(),
    };
    let ep_title = episode.title.clone().unwrap_or_default();

    rsx! {
        li { class: "py-2 flex items-center justify-between gap-4",
            div { class: "min-w-0",
                div { class: "font-medium truncate", "{show_title}" }
                div { class: "text-sm opacity-70 truncate",
                    if !label.is_empty() {
                        span { class: "font-mono mr-2", "{label}" }
                    }
                    if !ep_title.is_empty() {
                        span { "{ep_title}" }
                    }
                }
            }
            div { class: "flex items-center gap-3 shrink-0",
                span { class: "text-xs opacity-60", "{episode.air_date}" }
                if episode.has_files {
                    span { class: "badge badge-success badge-sm", "In library" }
                }
            }
        }
    }
}

/// Render a count as a string with a thousands separator. Plays nice
/// at low counts (returns `"0"`/`"42"`) and at high (`"1,234,567"`).
fn format_count(n: i64) -> String {
    let raw = n.to_string();
    let bytes = raw.as_bytes();
    let mut out = String::with_capacity(raw.len() + raw.len() / 3);
    let start_neg = bytes.first() == Some(&b'-');
    let digits = if start_neg { &bytes[1..] } else { bytes };
    if start_neg {
        out.push('-');
    }
    for (i, b) in digits.iter().enumerate() {
        if i > 0 && (digits.len() - i) % 3 == 0 {
            out.push(',');
        }
        out.push(*b as char);
    }
    out
}

/// Format bytes as a human-readable string. Mirrors Phoenix's
/// `format_bytes/1` helper closely enough that the dashboard reads
/// the same.
fn format_bytes(bytes: i64) -> String {
    if bytes < 0 {
        return "—".to_owned();
    }
    let bytes = bytes as f64;
    if bytes < 1024.0 {
        return format!("{bytes:.0} B");
    }
    let units = ["KB", "MB", "GB", "TB", "PB"];
    let mut value = bytes / 1024.0;
    let mut unit_idx = 0;
    while value >= 1024.0 && unit_idx < units.len() - 1 {
        value /= 1024.0;
        unit_idx += 1;
    }
    format!("{:.2} {}", value, units[unit_idx])
}
