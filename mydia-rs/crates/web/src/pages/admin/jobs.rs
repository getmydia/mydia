//! Admin → Background Jobs page.
//!
//! Phoenix counterpart: `MydiaWeb.JobsLive.Index`. The Phoenix
//! version paginates the Oban history table; the Rust port renders a
//! worker-summary table (one row per known apalis worker) and a
//! live "recent events" feed driven by the `jobs:status` pubsub
//! topic.
//!
//! Why that shape: apalis 0.7's storage doesn't expose a portable
//! history query — only the pending-count via `len()`. Building a
//! Phoenix-parity history view would require either denormalising
//! jobs into a side table or reaching into apalis-sql's `Jobs` table
//! directly. Both are larger changes than U28 is willing to absorb,
//! so the live feed (which the operator was reaching for the page
//! to see anyway) is the U28 surface; deeper history lands as a
//! follow-up.

use std::collections::VecDeque;

use dioxus::fullstack::{use_websocket, WebSocketOptions};
use dioxus::prelude::*;

use crate::components::admin::{AdminPageHeader, StatusPill};
use crate::components::core::{Button, ButtonSize, ButtonVariant};
use crate::realtime::jobs_status::{jobs_status_ws, JobStatusEvent};
use crate::server_fns::admin::jobs::{trigger_job, worker_summary, WorkerRow};

/// How many recent events to keep in the live feed before dropping
/// the oldest. Sized to cover roughly a minute of typical activity.
const FEED_CAPACITY: usize = 50;

#[component]
pub fn Jobs() -> Element {
    let mut reload_token = use_signal(|| 0_u64);
    let summary = use_resource(move || {
        let _ = reload_token.read();
        async move { worker_summary().await }
    });

    let feed: Signal<VecDeque<JobStatusEvent>> = use_signal(VecDeque::new);
    let mut ws = use_websocket(|| jobs_status_ws(WebSocketOptions::new()));

    use_future(move || {
        let mut feed = feed;
        let mut reload_token = reload_token;
        async move {
            loop {
                match ws.recv().await {
                    Ok(event) => {
                        let is_terminal =
                            matches!(event.kind.as_str(), "stop" | "exception" | "exit");
                        feed.with_mut(|q| {
                            q.push_front(event);
                            while q.len() > FEED_CAPACITY {
                                q.pop_back();
                            }
                        });
                        // Pending-count refresh on terminals so the
                        // summary table stays honest with the queue
                        // depth. Phoenix's `handle_info({:job_completed, _}, _)`
                        // does the same reload.
                        if is_terminal {
                            reload_token.with_mut(|t| *t += 1);
                        }
                    }
                    Err(err) => {
                        tracing::warn!(?err, "jobs status WS recv error; stopping fan-in");
                        break;
                    }
                }
            }
        }
    });

    let refresh = move |_| reload_token.with_mut(|t| *t += 1);

    rsx! {
        div { class: "max-w-5xl mx-auto",
            AdminPageHeader {
                title: "Background jobs".to_string(),
                subtitle: Some(
                    "Apalis-backed workers feeding the library, transcoder, and metadata stack."
                        .to_string(),
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

            section { class: "card bg-base-100 shadow mb-6",
                div { class: "card-body",
                    h2 { class: "card-title text-lg", "Workers" }
                    match &*summary.read_unchecked() {
                        Some(Ok(s)) => rsx! {
                            div { class: "overflow-x-auto",
                                table { class: "table",
                                    thead {
                                        tr {
                                            th { "Worker" }
                                            th { "Pending" }
                                            th { class: "text-right", "Actions" }
                                        }
                                    }
                                    tbody { id: "admin-jobs-workers",
                                        for worker in s.workers.iter().cloned() {
                                            JobWorkerRowView {
                                                key: "{worker.worker_id}",
                                                worker: worker,
                                                on_changed: move || reload_token.with_mut(|t| *t += 1),
                                            }
                                        }
                                    }
                                }
                            }
                            div { class: "text-xs text-base-content/60 mt-2",
                                "Loaded {s.generated_at}"
                            }
                        },
                        Some(Err(err)) => rsx! {
                            div { class: "alert alert-error", "Failed to load workers: {err}" }
                        },
                        None => rsx! {
                            div { class: "py-8 text-center",
                                span { class: "loading loading-spinner loading-md" }
                            }
                        },
                    }
                }
            }

            section { class: "card bg-base-100 shadow",
                div { class: "card-body",
                    h2 { class: "card-title text-lg", "Live event feed" }
                    {
                        let events = feed.read().clone();
                        if events.is_empty() {
                            rsx! {
                                div { id: "admin-jobs-empty-feed", class: "text-sm text-base-content/60 py-6 text-center",
                                    "Waiting for activity..."
                                }
                            }
                        } else {
                            rsx! {
                                ul { class: "space-y-1",
                                    for (idx, event) in events.iter().enumerate() {
                                        li {
                                            key: "{idx}",
                                            class: "flex items-center gap-2 text-sm",
                                            StatusPill {
                                                status: event.kind.clone(),
                                                label: Some(event.kind.clone()),
                                            }
                                            span { class: "font-mono", "{event.worker_id}" }
                                            if !event.payload.is_null() {
                                                span { class: "text-base-content/60", "{event.payload}" }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

#[derive(Props, Clone, PartialEq)]
struct JobWorkerRowProps {
    worker: WorkerRow,
    on_changed: Callback<()>,
}

#[component]
fn JobWorkerRowView(props: JobWorkerRowProps) -> Element {
    let mut acting = use_signal(|| false);
    let worker_id_for_trigger = props.worker.worker_id.clone();
    let on_changed = props.on_changed;

    let on_trigger = move |_| {
        if *acting.read() {
            return;
        }
        acting.set(true);
        let id = worker_id_for_trigger.clone();
        spawn(async move {
            if let Err(err) = trigger_job(id).await {
                tracing::warn!(%err, "trigger_job failed");
            }
            on_changed.call(());
            acting.set(false);
        });
    };

    let pending_text = props
        .worker
        .pending
        .map_or_else(|| "-".to_string(), |n| n.to_string());

    rsx! {
        tr {
            td {
                div { class: "font-medium", "{props.worker.label}" }
                div { class: "text-xs text-base-content/60 font-mono", "{props.worker.worker_id}" }
            }
            td { "{pending_text}" }
            td { class: "text-right",
                Button {
                    variant: ButtonVariant::Primary,
                    size: ButtonSize::Sm,
                    disabled: !props.worker.triggerable || *acting.read(),
                    loading: *acting.read(),
                    onclick: on_trigger,
                    "Run now"
                }
            }
        }
    }
}
