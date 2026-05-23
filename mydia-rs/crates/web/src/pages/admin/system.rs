//! Admin → Configuration → Status page.
//!
//! Phoenix counterpart: `MydiaWeb.AdminSystemLive.Index` (the
//! "Status" tab). Renders a read-only snapshot of process + database
//! health plus the headline counts an operator wants to confirm a
//! fresh install is wired up (library paths configured, download
//! clients configured, indexers configured).
//!
//! No real-time channel — the Phoenix page uses a `timer.send_interval`
//! to repaint every 5 seconds. We achieve the same with a manual
//! "Refresh" button + a reload-token signal. Promoting to a
//! `system_status_ws` WebSocket can land if operators ask for it,
//! but the polling shape is honest about what the data actually
//! costs.

use dioxus::prelude::*;

use crate::components::admin::{AdminPageHeader, ConfigSection, StatRow, StatusPill};
use crate::components::core::{Button, ButtonSize, ButtonVariant};
use crate::server_fns::admin::system::{system_status, SystemStatus};

#[component]
pub fn System() -> Element {
    let mut reload_token = use_signal(|| 0_u64);
    let status = use_resource(move || {
        let _ = reload_token.read();
        async move { system_status().await }
    });

    let refresh = move |_| reload_token.with_mut(|t| *t += 1);

    rsx! {
        div { class: "max-w-5xl mx-auto",
            AdminPageHeader {
                title: "System status".to_string(),
                subtitle: Some(
                    "Process, database, and pipeline health at a glance.".to_string(),
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

            match &*status.read_unchecked() {
                Some(Ok(snapshot)) => rsx! { StatusBody { snapshot: snapshot.clone() } },
                Some(Err(err)) => rsx! {
                    div { class: "alert alert-error", "Failed to load status: {err}" }
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

#[derive(Props, Clone, PartialEq)]
struct StatusBodyProps {
    snapshot: SystemStatus,
}

#[component]
fn StatusBody(props: StatusBodyProps) -> Element {
    let s = props.snapshot.clone();
    rsx! {
        ConfigSection {
            id: "admin-system-process".to_string(),
            title: "Process".to_string(),
            description: Some("Build, target, and uptime for this Mydia node.".to_string()),
            StatRow { label: "App version".to_string(), value: s.app_version.clone() }
            StatRow { label: "Build target".to_string(), value: s.build_target.clone() }
            StatRow { label: "Uptime".to_string(), value: s.uptime.clone() }
        }

        ConfigSection {
            id: "admin-system-database".to_string(),
            title: "Database".to_string(),
            description: Some("Adapter, location, and current pool health.".to_string()),
            actions: rsx! {
                StatusPill {
                    status: if s.database_health == "healthy" { "active".to_string() } else { "error".to_string() },
                    label: Some(s.database_health.clone()),
                }
            },
            StatRow { label: "Adapter".to_string(), value: s.database_adapter.clone() }
            StatRow { label: "Location".to_string(), value: s.database_location.clone() }
            StatRow { label: "Size".to_string(), value: s.database_size.clone() }
        }

        ConfigSection {
            id: "admin-system-pipeline".to_string(),
            title: "Pipeline".to_string(),
            description: Some("Active counts for the workers operators reach for first.".to_string()),
            StatRow { label: "Library paths".to_string(), value: s.library_paths_count.to_string() }
            StatRow { label: "Download clients".to_string(), value: s.download_clients_count.to_string() }
            StatRow { label: "Indexers".to_string(), value: s.indexers_count.to_string() }
            StatRow { label: "Active transcodes".to_string(), value: s.active_transcodes.to_string() }
            StatRow { label: "Streaming sessions".to_string(), value: s.active_streaming_sessions.to_string() }
        }
    }
}
