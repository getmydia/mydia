//! User-side requests page.
//!
//! Phoenix counterpart: `MydiaWeb.MyRequestsLive.Index`. Lists the
//! session user's `media_requests` rows with a status filter (pending
//! / approved / rejected / all). The Phoenix page uses `current_user.id`
//! straight off the socket assigns; the Rust port pulls the user from
//! the session inside `list_my_requests`.

use dioxus::prelude::*;

use crate::components::admin::{AdminPageHeader, FilterBar, FilterOption, StatusPill};
use crate::components::core::{Button, ButtonSize, ButtonVariant};
use crate::server_fns::requests::list_my_requests;

const FILTER_OPTIONS: &[(&str, &str)] = &[
    ("all", "All"),
    ("pending", "Pending"),
    ("approved", "Approved"),
    ("rejected", "Rejected"),
];

#[component]
pub fn MyRequests() -> Element {
    let filter = use_signal(|| "all".to_owned());
    let mut reload_token = use_signal(|| 0_u64);
    let requests = use_resource(move || {
        let filter = filter.read().clone();
        let _ = reload_token.read();
        async move { list_my_requests(filter).await }
    });

    let on_select_filter = {
        let mut filter = filter;
        move |value: String| filter.set(value)
    };
    let refresh = move |_| reload_token.with_mut(|t| *t += 1);

    rsx! {
        div { class: "max-w-3xl mx-auto",
            AdminPageHeader {
                title: "My requests".to_string(),
                subtitle: Some(
                    "Your pending, approved, and rejected media requests.".to_string(),
                ),
                actions: rsx! {
                    Button {
                        variant: ButtonVariant::Ghost,
                        size: ButtonSize::Sm,
                        onclick: refresh,
                        "Refresh"
                    }
                },
            }

            div { class: "mb-4",
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
                    match &*requests.read_unchecked() {
                        Some(Ok(rows)) if rows.is_empty() => rsx! {
                            div { id: "my-requests-empty", class: "text-sm text-base-content/60 py-12 text-center",
                                "You haven't made any requests yet."
                            }
                        },
                        Some(Ok(rows)) => rsx! {
                            ul { id: "my-requests-rows", class: "divide-y divide-base-content/5",
                                for row in rows.iter().cloned() {
                                    li { key: "{row.id}", class: "py-3 flex items-start gap-3",
                                        div { class: "flex-1 min-w-0",
                                            div { class: "flex items-center gap-2 flex-wrap",
                                                span { class: "font-medium", "{row.title}" }
                                                if let Some(year) = row.year {
                                                    span { class: "text-xs text-base-content/60", "({year})" }
                                                }
                                                StatusPill { status: row.status.clone() }
                                            }
                                            if let Some(notes) = row.requester_notes.as_deref() {
                                                div { class: "text-xs italic text-base-content/70 mt-1",
                                                    "Note: {notes}"
                                                }
                                            }
                                            if let Some(reason) = row.rejection_reason.as_deref() {
                                                div { class: "text-xs text-error mt-1",
                                                    "Rejected: {reason}"
                                                }
                                            }
                                            if let Some(notes) = row.admin_notes.as_deref() {
                                                div { class: "text-xs text-base-content/70 mt-1",
                                                    "Admin: {notes}"
                                                }
                                            }
                                        }
                                        div { class: "shrink-0 text-right",
                                            div { class: "text-xs text-base-content/60 capitalize", "{row.media_type}" }
                                            if let Some(at) = row.inserted_at.as_deref() {
                                                div { class: "text-xs text-base-content/50",
                                                    {at.chars().take(10).collect::<String>()}
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        },
                        Some(Err(err)) => rsx! {
                            div { class: "alert alert-error", "Failed to load requests: {err}" }
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
