//! Admin → Configuration → Remote access page.
//!
//! Phoenix counterpart: `MydiaWeb.AdminRemoteAccessLive`. Operator-
//! facing view of every paired remote device across all users.
//! Distinct from the per-user [`super::devices`] page, which scopes
//! to the acting admin's session.
//!
//! The Phoenix surface includes a generated-pairing-token panel —
//! that flow lives in `pages/admin/devices` (U28 operational
//! slice). The remote-access page focuses on the cross-user roll-up.

use dioxus::prelude::*;

use crate::components::admin::{AdminPageHeader, ConfigSection, StatRow, StatusPill};
use crate::components::core::{Button, ButtonSize, ButtonVariant};
use crate::server_fns::admin::remote_access::{
    list_paired_devices, remote_access_status, revoke_paired_device, P2pStatus, PairedDeviceRow,
};

#[component]
pub fn RemoteAccess() -> Element {
    let mut reload_token = use_signal(|| 0_u64);
    let devices = use_resource(move || {
        let _ = reload_token.read();
        async move { list_paired_devices().await }
    });
    let status = use_resource(move || {
        let _ = reload_token.read();
        async move { remote_access_status().await }
    });

    rsx! {
        div { class: "max-w-5xl mx-auto",
            AdminPageHeader {
                title: "Remote access".to_string(),
                subtitle: Some(
                    "Paired devices across the mesh. Revoke any row to evict it.".to_string(),
                ),
                actions: rsx! {
                    Button {
                        variant: ButtonVariant::Ghost,
                        size: ButtonSize::Sm,
                        onclick: move |_| reload_token.with_mut(|t| *t += 1),
                        "Refresh"
                    }
                },
            }

            match &*status.read_unchecked() {
                Some(Ok(s)) => rsx! { StatusCard { status: s.clone() } },
                Some(Err(err)) => rsx! {
                    div { class: "alert alert-error mb-6", "Failed to load p2p status: {err}" }
                },
                None => rsx! {
                    div { class: "py-4 text-center",
                        span { class: "loading loading-spinner loading-sm" }
                    }
                },
            }

            ConfigSection {
                id: "admin-remote-access-devices".to_string(),
                title: "Paired devices".to_string(),
                match &*devices.read_unchecked() {
                    Some(Ok(rows)) => {
                        if rows.is_empty() {
                            rsx! {
                                div { id: "admin-remote-access-empty", class: "text-sm text-base-content/60 py-12 text-center",
                                    "No paired devices yet."
                                }
                            }
                        } else {
                            let rows = rows.clone();
                            rsx! {
                                div { class: "overflow-x-auto",
                                    table { class: "table",
                                        thead {
                                            tr {
                                                th { "Device" }
                                                th { "User" }
                                                th { "Platform" }
                                                th { "Last seen" }
                                                th { "Status" }
                                                th { class: "text-right", "Actions" }
                                            }
                                        }
                                        tbody { id: "admin-remote-access-rows",
                                            for row in rows.into_iter() {
                                                DeviceRowView {
                                                    key: "{row.id}",
                                                    row: row,
                                                    on_changed: move || reload_token.with_mut(|t| *t += 1),
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    Some(Err(err)) => rsx! {
                        div { class: "alert alert-error", "Failed to load paired devices: {err}" }
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

#[derive(Props, Clone, PartialEq)]
struct StatusCardProps {
    status: P2pStatus,
}

#[component]
fn StatusCard(props: StatusCardProps) -> Element {
    let s = props.status.clone();
    rsx! {
        ConfigSection {
            id: "admin-remote-access-status".to_string(),
            title: "P2P node".to_string(),
            StatRow { label: "Paired devices".to_string(), value: s.paired_devices.to_string() }
            StatRow { label: "Revoked devices".to_string(), value: s.revoked_devices.to_string() }
            if let Some(summary) = s.last_seen_summary.as_ref() {
                StatRow { label: "Last activity".to_string(), value: summary.clone() }
            }
        }

        // The live host status section renders only when the p2p
        // Server is actually running. When `running == false` the
        // backend either skipped p2p boot (no keypair configured) or
        // remote access is disabled outright; either way there's no
        // Iroh state to show, so we omit the section to avoid
        // confusing empty rows.
        if s.running {
            LiveHostStatusCard { status: s.clone() }
        }
    }
}

#[component]
fn LiveHostStatusCard(props: StatusCardProps) -> Element {
    let s = props.status.clone();
    rsx! {
        ConfigSection {
            id: "admin-remote-access-live-status".to_string(),
            title: "Live host status".to_string(),
            StatRow { label: "Node identifier".to_string(), value: s.node_id.clone() }
            StatRow {
                label: "Connected peers".to_string(),
                value: s.connected_peers.to_string(),
            }
            StatRow {
                label: "Relay".to_string(),
                value: format!(
                    "{} ({})",
                    if s.relay_connected { "connected" } else { "disconnected" },
                    s.relay_url.clone().unwrap_or_else(|| "iroh default".to_owned()),
                ),
            }
            if let Some(kind) = s.peer_connection_type.as_ref() {
                StatRow { label: "Peer connection type".to_string(), value: kind.clone() }
            }
            if let Some(addr) = s.node_addr.as_ref() {
                StatRow { label: "Node address".to_string(), value: addr.clone() }
            }
        }
    }
}

#[derive(Props, Clone, PartialEq)]
struct DeviceRowProps {
    row: PairedDeviceRow,
    on_changed: Callback<()>,
}

#[component]
fn DeviceRowView(props: DeviceRowProps) -> Element {
    let mut acting = use_signal(|| false);
    let id_for_revoke = props.row.id.clone();
    let on_changed = props.on_changed;

    let revoke = move |_| {
        if *acting.read() {
            return;
        }
        acting.set(true);
        let id = id_for_revoke.clone();
        spawn(async move {
            let _ = revoke_paired_device(id).await;
            on_changed.call(());
            acting.set(false);
        });
    };

    let is_revoked = props.row.revoked_at.is_some();
    let status_label = if is_revoked { "Revoked" } else { "Active" };
    let status_kind = if is_revoked { "revoked" } else { "active" };

    let last_seen = props
        .row
        .last_seen_at
        .clone()
        .unwrap_or_else(|| "Never".to_owned());
    let user_label = props
        .row
        .user_label
        .clone()
        .unwrap_or_else(|| props.row.user_id.clone());

    rsx! {
        tr {
            td { class: "font-medium", "{props.row.device_name}" }
            td { class: "text-sm", "{user_label}" }
            td { class: "capitalize", "{props.row.platform}" }
            td { class: "text-xs", "{last_seen}" }
            td {
                StatusPill {
                    status: status_kind.to_string(),
                    label: Some(status_label.to_string()),
                }
            }
            td { class: "text-right whitespace-nowrap",
                if !is_revoked {
                    Button {
                        variant: ButtonVariant::Error,
                        size: ButtonSize::Sm,
                        onclick: revoke,
                        "Revoke"
                    }
                } else {
                    span { class: "text-xs text-base-content/60", "—" }
                }
            }
        }
    }
}
