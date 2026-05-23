//! Calendar month grid component.
//!
//! Phoenix counterpart: the `<.calendar_grid>` block in
//! `lib/mydia_web/live/calendar_live/index.html.heex`. Renders a
//! Monday-first 7-column grid with one row per week; each cell carries
//! the day number plus a stack of entry pills (episode S01E01-style or
//! movie title).
//!
//! The component is pure: the page passes in the resolved entries plus
//! the displayed month, and the grid draws the boxes. Date math (which
//! week a day falls in, padding for the first week) happens here in
//! pure functions so the page stays focused on data loading.

use dioxus::prelude::*;

use crate::components::core::Icon;
use crate::server_fns::calendar::CalendarEntry;

#[derive(Props, Clone, PartialEq)]
pub struct CalendarGridProps {
    pub year: i32,
    pub month: u32,
    pub entries: Vec<CalendarEntry>,
    /// `YYYY-MM-DD` string for "today" — server-provided so the wasm
    /// client doesn't need `chrono`.
    pub today: String,
}

#[component]
pub fn CalendarGrid(props: CalendarGridProps) -> Element {
    let days = calendar_days(props.year, props.month, &props.entries, &props.today);

    rsx! {
        div { class: "grid grid-cols-7 gap-1 bg-base-200",
            // Weekday headers — Monday first, matching the Phoenix grid.
            for day_name in &["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"] {
                div { class: "text-xs uppercase font-semibold text-base-content/60 py-2 text-center",
                    "{day_name}"
                }
            }

            for (idx, cell) in days.iter().enumerate() {
                if let Some(cell) = cell.as_ref() {
                    CalendarCell { key: "{idx}", cell: cell.clone() }
                } else {
                    div { key: "{idx}", class: "min-h-[80px] bg-base-100/40" }
                }
            }
        }
    }
}

#[derive(Clone, PartialEq, Eq)]
struct DayCell {
    day: u32,
    is_today: bool,
    entries: Vec<CalendarEntry>,
}

#[derive(Props, Clone, PartialEq)]
struct CalendarCellProps {
    cell: DayCell,
}

#[component]
fn CalendarCell(props: CalendarCellProps) -> Element {
    let day = props.cell.day;
    let is_today = props.cell.is_today;
    let outer_class = if is_today {
        "min-h-[80px] bg-base-100 ring-2 ring-primary p-1 overflow-hidden"
    } else {
        "min-h-[80px] bg-base-100 p-1 overflow-hidden"
    };
    let day_class = if is_today {
        "text-xs font-bold text-primary"
    } else {
        "text-xs font-semibold text-base-content/70"
    };

    rsx! {
        div { class: "{outer_class}",
            div { class: "{day_class}", "{day}" }
            div { class: "mt-1 space-y-0.5",
                for entry in props.cell.entries.iter() {
                    EntryPill {
                        key: "{entry.id}",
                        entry: entry.clone(),
                    }
                }
            }
        }
    }
}

#[derive(Props, Clone, PartialEq)]
struct EntryPillProps {
    entry: CalendarEntry,
}

#[component]
fn EntryPill(props: EntryPillProps) -> Element {
    let entry = props.entry;
    let status_class = entry_status_class(&entry);

    let label = match entry.kind.as_str() {
        "episode" => format_episode_label(&entry),
        "movie" => entry
            .media_item_title
            .clone()
            .unwrap_or_else(|| "Movie".to_owned()),
        _ => entry.title.clone().unwrap_or_default(),
    };
    let icon_name = if entry.kind == "movie" { "film" } else { "tv" };
    let href = format!("/media/{}", entry.media_item_id);

    rsx! {
        a {
            href: "{href}",
            class: "flex items-center gap-1 text-[10px] px-1 py-0.5 rounded {status_class} truncate",
            title: "{label}",
            Icon { name: icon_name.to_string(), class: "w-3 h-3 shrink-0".to_string() }
            span { class: "truncate", "{label}" }
        }
    }
}

fn format_episode_label(entry: &CalendarEntry) -> String {
    let (Some(s), Some(e)) = (entry.season_number, entry.episode_number) else {
        return entry
            .media_item_title
            .clone()
            .unwrap_or_else(|| "Episode".to_owned());
    };
    let show = entry.media_item_title.as_deref().unwrap_or("Show");
    format!("S{s:02}E{e:02} {show}")
}

fn entry_status_class(entry: &CalendarEntry) -> &'static str {
    // Matches the Phoenix `status_color` palette (downloaded / downloading /
    // upcoming / missing). The fallback is upcoming since the calendar is
    // dominated by future content.
    if entry.has_files {
        "bg-success/30 text-success-content"
    } else if entry.has_downloads {
        "bg-info/30 text-info-content"
    } else {
        "bg-base-200 text-base-content"
    }
}

/// Build the day-cell grid for a given month. Returns 6 weeks × 7 days
/// = 42 cells, with leading `None`s for the days of the previous month
/// that pad the first week and trailing `None`s for the days after the
/// last of the month. Monday is the first day of the week.
fn calendar_days(
    year: i32,
    month: u32,
    entries: &[CalendarEntry],
    today_iso: &str,
) -> Vec<Option<DayCell>> {
    let (start_weekday, days_in_month) = month_layout(year, month);
    // Phoenix uses Monday=1..=Sunday=7. The Rust standard library's
    // `chrono` `Datelike::weekday().num_days_from_monday()` is 0..=6;
    // we don't want chrono on the wasm path, so we recompute via
    // Zeller's-ish identity directly. The padding count is just the
    // 0-indexed Monday-relative weekday.
    let pad = start_weekday;

    let mut cells: Vec<Option<DayCell>> = Vec::with_capacity(42);
    for _ in 0..pad {
        cells.push(None);
    }

    for day in 1..=days_in_month {
        let iso = format!("{year:04}-{month:02}-{day:02}");
        let cell_entries: Vec<CalendarEntry> = entries
            .iter()
            .filter(|e| e.air_date == iso)
            .cloned()
            .collect();
        cells.push(Some(DayCell {
            day,
            is_today: iso == today_iso,
            entries: cell_entries,
        }));
    }

    while cells.len() < 42 {
        cells.push(None);
    }
    cells
}

/// Returns `(weekday_of_day_1_monday_relative, days_in_month)`.
///
/// `weekday_of_day_1_monday_relative` is 0 for Monday, 6 for Sunday.
/// `days_in_month` is 28, 29, 30, or 31. Both computations avoid
/// `chrono` so the component compiles on the wasm target.
#[allow(clippy::cast_possible_wrap, clippy::cast_sign_loss)]
fn month_layout(year: i32, month: u32) -> (u32, u32) {
    let days_in_month = match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31_u32,
        2 if is_leap_year(year) => 29,
        2 => 28,
        _ => 30,
    };

    // Zeller's congruence (Gregorian, ISO-Monday=0..Sunday=6).
    let (year_adj, month_adj) = if month < 3 {
        (year - 1, month + 12)
    } else {
        (year, month)
    };
    let century_year = (year_adj % 100 + 400) % 100;
    let century = year_adj.div_euclid(100);
    let month_i32 = month_adj as i32;
    let zeller = (1
        + (13 * (month_i32 + 1)) / 5
        + century_year
        + century_year / 4
        + century / 4
        + 5 * century)
        .rem_euclid(7);
    // Zeller: 0=Saturday..6=Friday. Map to Monday-relative 0..=6.
    let monday_relative: u32 = match zeller {
        0 => 5, // Saturday
        1 => 6, // Sunday
        2 => 0, // Monday
        3 => 1, // Tuesday
        4 => 2, // Wednesday
        5 => 3, // Thursday
        _ => 4, // Friday
    };
    (monday_relative, days_in_month)
}

fn is_leap_year(year: i32) -> bool {
    (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn month_layout_january_2024_starts_monday() {
        // 2024-01-01 is a Monday.
        let (pad, days) = month_layout(2024, 1);
        assert_eq!(pad, 0);
        assert_eq!(days, 31);
    }

    #[test]
    fn month_layout_february_2024_is_leap_year() {
        let (_, days) = month_layout(2024, 2);
        assert_eq!(days, 29);
    }

    #[test]
    fn month_layout_february_2023_not_leap() {
        let (_, days) = month_layout(2023, 2);
        assert_eq!(days, 28);
    }

    #[test]
    fn month_layout_may_2026_starts_friday() {
        // 2026-05-01 is a Friday.
        let (pad, days) = month_layout(2026, 5);
        assert_eq!(pad, 4);
        assert_eq!(days, 31);
    }

    #[test]
    fn calendar_days_returns_42_cells() {
        let cells = calendar_days(2026, 5, &[], "2026-05-23");
        assert_eq!(cells.len(), 42);
    }

    #[test]
    fn calendar_days_marks_today() {
        let cells = calendar_days(2026, 5, &[], "2026-05-23");
        let today_cell = cells
            .iter()
            .flatten()
            .find(|c| c.day == 23)
            .expect("day 23 present");
        assert!(today_cell.is_today);
    }

    #[test]
    fn entry_status_class_downloaded() {
        let e = CalendarEntry {
            id: "x".to_owned(),
            kind: "movie".to_owned(),
            air_date: "2026-05-23".to_owned(),
            title: None,
            season_number: None,
            episode_number: None,
            media_item_id: "m".to_owned(),
            media_item_title: None,
            media_item_type: Some("movie".to_owned()),
            has_files: true,
            has_downloads: false,
        };
        assert!(entry_status_class(&e).contains("bg-success"));
    }
}
