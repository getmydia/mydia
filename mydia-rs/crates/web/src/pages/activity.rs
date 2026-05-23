//! Activity feed page.
//!
//! Phoenix counterpart: `MydiaWeb.ActivityLive.Index`. Lists recent
//! events from the `events` table with filter pills for category and
//! date preset. The Phoenix page uses `LiveView` streams + a real-time
//! `events:all` `PubSub` fan-in; the Rust port keeps the same surface
//! sans the live fan-in (a TODO marker calls out the gap; the page is
//! useful as-is without it).

use dioxus::prelude::*;

use crate::components::activity_event::ActivityEventRow;
use crate::components::admin::{AdminPageHeader, FilterBar, FilterOption};
use crate::components::core::{Button, ButtonSize, ButtonVariant};
use crate::server_fns::activity::{list_activity, ActivityQuery};

const CATEGORY_OPTIONS: &[(&str, &str)] = &[
    ("all", "All"),
    ("errors", "Errors"),
    ("media_item", "Library"),
    ("download", "Downloads"),
    ("job", "Jobs"),
    ("search", "Search"),
];

const DATE_OPTIONS: &[(&str, &str)] = &[
    ("all", "All time"),
    ("today", "Today"),
    ("yesterday", "Yesterday"),
    ("week", "Past week"),
    ("month", "Past month"),
];

#[component]
pub fn Activity() -> Element {
    let category = use_signal(|| "all".to_owned());
    let date_filter = use_signal(|| "all".to_owned());
    let page = use_signal(|| 0_i64);

    let activity = use_resource(move || {
        let category = category.read().clone();
        let date_filter = date_filter.read().clone();
        let page_val = *page.read();
        async move {
            list_activity(ActivityQuery {
                category,
                date_filter,
                page: page_val,
            })
            .await
        }
    });

    let on_category = {
        let mut category = category;
        let mut page = page;
        move |value: String| {
            category.set(value);
            page.set(0);
        }
    };

    let on_date = {
        let mut date_filter = date_filter;
        let mut page = page;
        move |value: String| {
            date_filter.set(value);
            page.set(0);
        }
    };

    let load_more = {
        let mut page = page;
        move |_| page.with_mut(|p| *p += 1)
    };

    let reset = {
        let mut page = page;
        move |_| page.set(0)
    };

    rsx! {
        div { class: "max-w-4xl mx-auto",
            AdminPageHeader {
                title: "Activity".to_string(),
                subtitle: Some(
                    "Recent library, download, search, and job events. Filter by category or time."
                        .to_string(),
                ),
                actions: rsx! {
                    Button {
                        variant: ButtonVariant::Ghost,
                        size: ButtonSize::Sm,
                        onclick: reset,
                        "Refresh"
                    }
                },
            }

            div { class: "flex flex-col gap-2 mb-4",
                FilterBar {
                    current: category.read().clone(),
                    options: CATEGORY_OPTIONS
                        .iter()
                        .map(|(v, l)| FilterOption::new(*v, *l))
                        .collect(),
                    on_select: on_category,
                }
                FilterBar {
                    current: date_filter.read().clone(),
                    options: DATE_OPTIONS
                        .iter()
                        .map(|(v, l)| FilterOption::new(*v, *l))
                        .collect(),
                    on_select: on_date,
                }
            }

            section { class: "card bg-base-100 shadow",
                div { class: "card-body",
                    match &*activity.read_unchecked() {
                        Some(Ok(view)) if view.events.is_empty() => rsx! {
                            div { id: "activity-empty", class: "text-sm text-base-content/60 py-12 text-center",
                                "No events match this filter yet."
                            }
                        },
                        Some(Ok(view)) => {
                            let has_more = view.has_more;
                            rsx! {
                                ul { id: "activity-events", class: "space-y-0",
                                    for event in view.events.iter().cloned() {
                                        ActivityEventRow { key: "{event.id}", event: event }
                                    }
                                }
                                if has_more {
                                    div { class: "mt-3 text-center",
                                        Button {
                                            variant: ButtonVariant::Ghost,
                                            size: ButtonSize::Sm,
                                            onclick: load_more,
                                            "Load more"
                                        }
                                    }
                                }
                            }
                        }
                        Some(Err(err)) => rsx! {
                            div { class: "alert alert-error", "Failed to load activity: {err}" }
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
