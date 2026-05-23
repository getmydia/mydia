//! Calendar page.
//!
//! Phoenix counterpart: `MydiaWeb.CalendarLive.Index`. Renders a month
//! grid of upcoming episodes and movies with a previous-month /
//! next-month / today triad and a movie/tv filter pill row. The
//! Phoenix page also subscribes to the `downloads` pubsub for badge
//! refresh; the mydia-rs port keeps the calendar as a pure-read page
//! (the sidebar already drives the global download badge from the
//! `LayoutData` context).

use dioxus::prelude::*;

use crate::components::admin::{AdminPageHeader, FilterBar, FilterOption};
use crate::components::calendar_grid::CalendarGrid;
use crate::components::core::{Button, ButtonSize, ButtonVariant};
use crate::server_fns::calendar::{list_calendar, CalendarQuery};

const FILTER_OPTIONS: &[(&str, &str)] =
    &[("all", "All"), ("movie", "Movies"), ("tv_show", "TV Shows")];

#[component]
pub fn Calendar() -> Element {
    // Today's date is server-supplied (via `today_iso`) so the wasm
    // build never reaches for chrono. We approximate it client-side
    // via the year/month values the page initializes with — the
    // server hydration step backfills the real "today" string.
    let initial = use_server_future(initial_view)?;
    let initial_view = initial
        .read()
        .clone()
        .and_then(Result::ok)
        .unwrap_or(InitialView {
            year: 2026,
            month: 5,
            today: "2026-05-01".to_owned(),
        });

    let year = use_signal(|| initial_view.year);
    let month = use_signal(|| initial_view.month);
    let filter = use_signal(|| "all".to_owned());
    let today = initial_view.today.clone();

    let entries = use_resource(move || async move {
        list_calendar(CalendarQuery {
            year: *year.read(),
            month: *month.read(),
            filter: filter.read().clone(),
        })
        .await
    });

    let on_select_filter = {
        let mut filter = filter;
        move |value: String| {
            filter.set(value);
        }
    };

    let on_prev = {
        let mut year = year;
        let mut month = month;
        move |_| {
            let (y, m) = prev_month(*year.read(), *month.read());
            year.set(y);
            month.set(m);
        }
    };

    let on_next = {
        let mut year = year;
        let mut month = month;
        move |_| {
            let (y, m) = next_month(*year.read(), *month.read());
            year.set(y);
            month.set(m);
        }
    };

    let on_today = {
        let mut year = year;
        let mut month = month;
        let today = today.clone();
        move |_| {
            // Today's ISO string is parsed here on the client; if the
            // server failed to populate it (use_server_future error
            // path), fall back to the current displayed month.
            if let Some((y, m, _)) = parse_iso_ymd(&today) {
                year.set(y);
                month.set(m);
            }
        }
    };

    let display_label = format_month_year(*year.read(), *month.read());

    rsx! {
        div { class: "max-w-6xl mx-auto",
            AdminPageHeader {
                title: "Calendar".to_string(),
                subtitle: Some(
                    "Upcoming episodes and movie releases. Filter by media type or jump to today."
                        .to_string(),
                ),
                actions: rsx! {
                    Button {
                        variant: ButtonVariant::Ghost,
                        size: ButtonSize::Sm,
                        onclick: on_prev,
                        "Previous"
                    }
                    Button {
                        variant: ButtonVariant::Ghost,
                        size: ButtonSize::Sm,
                        onclick: on_today,
                        "Today"
                    }
                    Button {
                        variant: ButtonVariant::Ghost,
                        size: ButtonSize::Sm,
                        onclick: on_next,
                        "Next"
                    }
                },
            }

            div { class: "flex items-center justify-between mb-3",
                h2 { class: "text-xl font-semibold", "{display_label}" }
                FilterBar {
                    current: filter.read().clone(),
                    options: FILTER_OPTIONS
                        .iter()
                        .map(|(v, l)| FilterOption::new(*v, *l))
                        .collect(),
                    on_select: on_select_filter,
                }
            }

            section { class: "card bg-base-100 shadow",
                div { class: "card-body",
                    match &*entries.read_unchecked() {
                        Some(Ok(items)) => {
                            let is_empty = items.is_empty();
                            rsx! {
                                if is_empty {
                                    div { id: "calendar-empty", class: "text-sm text-base-content/60 py-12 text-center",
                                        "No upcoming releases for this month."
                                    }
                                }
                                CalendarGrid {
                                    year: *year.read(),
                                    month: *month.read(),
                                    entries: items.clone(),
                                    today: today.clone(),
                                }
                            }
                        }
                        Some(Err(err)) => rsx! {
                            div { class: "alert alert-error", "Failed to load calendar: {err}" }
                        },
                        None => rsx! {
                            div { class: "py-8 text-center",
                                span { class: "loading loading-spinner loading-md" }
                            }
                        },
                    }
                }
            }
        }
    }
}

/// Shared "view bootstrap" data the server resolves once at mount.
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
struct InitialView {
    year: i32,
    month: u32,
    today: String,
}

#[cfg(feature = "server")]
async fn initial_view() -> Result<InitialView, dioxus::fullstack::ServerFnError> {
    use chrono::{Datelike, Utc};
    let today = Utc::now().date_naive();
    Ok(InitialView {
        year: today.year(),
        month: today.month(),
        today: today.format("%Y-%m-%d").to_string(),
    })
}

#[cfg(not(feature = "server"))]
async fn initial_view() -> Result<InitialView, dioxus::fullstack::ServerFnError> {
    Err(dioxus::fullstack::ServerFnError::new(
        "server-only".to_owned(),
    ))
}

fn prev_month(year: i32, month: u32) -> (i32, u32) {
    if month <= 1 {
        (year - 1, 12)
    } else {
        (year, month - 1)
    }
}

fn next_month(year: i32, month: u32) -> (i32, u32) {
    if month >= 12 {
        (year + 1, 1)
    } else {
        (year, month + 1)
    }
}

fn parse_iso_ymd(s: &str) -> Option<(i32, u32, u32)> {
    let mut parts = s.split('-');
    let y = parts.next()?.parse::<i32>().ok()?;
    let m = parts.next()?.parse::<u32>().ok()?;
    let d = parts.next()?.parse::<u32>().ok()?;
    Some((y, m, d))
}

fn format_month_year(year: i32, month: u32) -> String {
    let name = match month {
        1 => "January",
        2 => "February",
        3 => "March",
        4 => "April",
        5 => "May",
        6 => "June",
        7 => "July",
        8 => "August",
        9 => "September",
        10 => "October",
        11 => "November",
        12 => "December",
        _ => "Unknown",
    };
    format!("{name} {year}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prev_month_rolls_over_january() {
        assert_eq!(prev_month(2026, 1), (2025, 12));
        assert_eq!(prev_month(2026, 5), (2026, 4));
    }

    #[test]
    fn next_month_rolls_over_december() {
        assert_eq!(next_month(2026, 12), (2027, 1));
        assert_eq!(next_month(2026, 5), (2026, 6));
    }

    #[test]
    fn parse_iso_ymd_round_trip() {
        assert_eq!(parse_iso_ymd("2026-05-23"), Some((2026, 5, 23)));
        assert_eq!(parse_iso_ymd("not-a-date"), None);
    }

    #[test]
    fn format_month_year_known_month() {
        assert_eq!(format_month_year(2026, 5), "May 2026");
    }
}
