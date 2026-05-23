//! Admin → User requests page.
//!
//! Phoenix counterpart: `MydiaWeb.AdminRequestsLive.Index`. Lists
//! `media_requests` rows filtered by status (default `pending`),
//! offers approve and reject flows.
//!
//! The Phoenix page wraps both flows in a modal so the admin can
//! attach an optional note (approve) or a required rejection reason
//! (reject). The Rust port keeps the same shape — inline-editable
//! row triggers a per-row modal — but lifts the modal state into the
//! row so multiple in-flight modals across the page don't fight over
//! one shared `selected_request` signal.

use dioxus::prelude::*;

use crate::components::admin::{AdminPageHeader, FilterBar, FilterOption, StatusPill};
use crate::components::core::{Button, ButtonSize, ButtonVariant, Input, Modal, ModalSize};
use crate::server_fns::admin::requests::{
    approve_request, list_requests, reject_request, ApproveRequest, RejectRequest, RequestRow,
};

const FILTER_OPTIONS: &[(&str, &str)] = &[
    ("pending", "Pending"),
    ("approved", "Approved"),
    ("rejected", "Rejected"),
    ("all", "All"),
];

#[component]
pub fn Requests() -> Element {
    let filter = use_signal(|| "pending".to_owned());
    let mut reload_token = use_signal(|| 0_u64);
    let requests = use_resource(move || {
        let filter = filter.read().clone();
        let _ = reload_token.read();
        async move { list_requests(filter).await }
    });

    let on_select_filter = {
        let mut filter = filter;
        move |value: String| {
            filter.set(value);
        }
    };

    rsx! {
        div { class: "max-w-5xl mx-auto",
            AdminPageHeader {
                title: "Media requests".to_string(),
                subtitle: Some("Approve or reject what guests have asked for.".to_string()),
                actions: rsx! {
                    Button {
                        variant: ButtonVariant::Ghost,
                        size: ButtonSize::Sm,
                        onclick: move |_| reload_token.with_mut(|t| *t += 1),
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
                            div { id: "admin-requests-empty", class: "text-sm text-base-content/60 py-12 text-center",
                                "No requests in this view."
                            }
                        },
                        Some(Ok(rows)) => rsx! {
                            div { class: "overflow-x-auto",
                                table { class: "table",
                                    thead {
                                        tr {
                                            th { "Title" }
                                            th { "Requester" }
                                            th { "Status" }
                                            th { class: "text-right", "Actions" }
                                        }
                                    }
                                    tbody { id: "admin-requests-rows",
                                        for row in rows.iter().cloned() {
                                            RequestRowView {
                                                key: "{row.id}",
                                                row: row,
                                                on_changed: move || reload_token.with_mut(|t| *t += 1),
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

#[derive(Props, Clone, PartialEq)]
struct RequestRowProps {
    row: RequestRow,
    on_changed: Callback<()>,
}

#[component]
fn RequestRowView(props: RequestRowProps) -> Element {
    let mut show_approve = use_signal(|| false);
    let mut show_reject = use_signal(|| false);
    let mut admin_notes = use_signal(String::new);
    let mut rejection_reason = use_signal(String::new);
    let mut acting = use_signal(|| false);
    let mut row_error = use_signal::<Option<String>>(|| None);

    let row_id_for_approve = props.row.id.clone();
    let row_id_for_reject = props.row.id.clone();
    let on_changed = props.on_changed;

    let submit_approve = move |_| {
        if *acting.read() {
            return;
        }
        acting.set(true);
        row_error.set(None);
        let id = row_id_for_approve.clone();
        let notes = admin_notes.read().clone();
        spawn(async move {
            let payload = ApproveRequest {
                id,
                admin_notes: (!notes.is_empty()).then_some(notes),
            };
            match approve_request(payload).await {
                Ok(_) => {
                    show_approve.set(false);
                    on_changed.call(());
                }
                Err(err) => row_error.set(Some(err.to_string())),
            }
            acting.set(false);
        });
    };

    let submit_reject = move |_| {
        if *acting.read() {
            return;
        }
        let reason = rejection_reason.read().clone();
        if reason.trim().is_empty() {
            row_error.set(Some("Rejection reason is required".to_owned()));
            return;
        }
        acting.set(true);
        row_error.set(None);
        let id = row_id_for_reject.clone();
        let notes = admin_notes.read().clone();
        spawn(async move {
            let payload = RejectRequest {
                id,
                rejection_reason: reason,
                admin_notes: (!notes.is_empty()).then_some(notes),
            };
            match reject_request(payload).await {
                Ok(_) => {
                    show_reject.set(false);
                    on_changed.call(());
                }
                Err(err) => row_error.set(Some(err.to_string())),
            }
            acting.set(false);
        });
    };

    let is_pending = props.row.status == "pending";

    let approve_modal_id = format!("admin-request-approve-{}", props.row.id);
    let reject_modal_id = format!("admin-request-reject-{}", props.row.id);

    rsx! {
        tr {
            td {
                div { class: "font-medium",
                    "{props.row.title}"
                    if let Some(year) = props.row.year {
                        span { class: "ml-2 text-base-content/60", "({year})" }
                    }
                }
                div { class: "text-xs text-base-content/60 capitalize", "{props.row.media_type}" }
                if let Some(notes) = props.row.requester_notes.as_ref() {
                    div { class: "text-xs italic text-base-content/70 mt-1", "{notes}" }
                }
            }
            td { class: "text-sm",
                {
                    props
                        .row
                        .requester_label
                        .clone()
                        .unwrap_or_else(|| "Unknown".to_string())
                }
            }
            td { StatusPill { status: props.row.status.clone() } }
            td { class: "text-right whitespace-nowrap",
                if is_pending {
                    Button {
                        variant: ButtonVariant::Success,
                        size: ButtonSize::Sm,
                        onclick: move |_| show_approve.set(true),
                        "Approve"
                    }
                    span { class: "mx-1" }
                    Button {
                        variant: ButtonVariant::Error,
                        size: ButtonSize::Sm,
                        onclick: move |_| show_reject.set(true),
                        "Reject"
                    }
                } else {
                    span { class: "text-xs text-base-content/60",
                        "{props.row.status}"
                    }
                }
            }
        }
        if let Some(err) = row_error.read().clone() {
            tr {
                td { colspan: "4", class: "text-xs text-error", "{err}" }
            }
        }

        // Approve modal
        Modal {
            id: approve_modal_id,
            open: *show_approve.read(),
            size: ModalSize::Md,
            on_close: move |()| show_approve.set(false),
            title: rsx! { "Approve request" },
            actions: rsx! {
                Button {
                    variant: ButtonVariant::Ghost,
                    onclick: move |_| show_approve.set(false),
                    "Cancel"
                }
                Button {
                    variant: ButtonVariant::Success,
                    onclick: submit_approve,
                    loading: *acting.read(),
                    "Approve"
                }
            },
            p { class: "text-sm mb-2",
                "Approve '{props.row.title}' for the library. Optional note attaches to the request record."
            }
            Input {
                name: "admin_notes".to_string(),
                r#type: "textarea".to_string(),
                label: "Admin notes (optional)".to_string(),
                value: "{admin_notes}",
                oninput: move |evt: FormEvent| admin_notes.set(evt.value()),
            }
        }

        // Reject modal
        Modal {
            id: reject_modal_id,
            open: *show_reject.read(),
            size: ModalSize::Md,
            on_close: move |()| show_reject.set(false),
            title: rsx! { "Reject request" },
            actions: rsx! {
                Button {
                    variant: ButtonVariant::Ghost,
                    onclick: move |_| show_reject.set(false),
                    "Cancel"
                }
                Button {
                    variant: ButtonVariant::Error,
                    onclick: submit_reject,
                    loading: *acting.read(),
                    "Reject"
                }
            },
            p { class: "text-sm mb-2",
                "Reject '{props.row.title}'. The reason is shown to the requester."
            }
            Input {
                name: "rejection_reason".to_string(),
                label: "Reason".to_string(),
                value: "{rejection_reason}",
                oninput: move |evt: FormEvent| rejection_reason.set(evt.value()),
                required: true,
            }
            Input {
                name: "admin_notes".to_string(),
                r#type: "textarea".to_string(),
                label: "Admin notes (optional)".to_string(),
                value: "{admin_notes}",
                oninput: move |evt: FormEvent| admin_notes.set(evt.value()),
            }
        }
    }
}
