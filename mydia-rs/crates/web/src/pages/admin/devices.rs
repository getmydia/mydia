//! Admin → Paired devices page.
//!
//! Phoenix counterpart: `MydiaWeb.AdminDevicesLive.Index`. The
//! Phoenix page lists every paired remote device for the current
//! user and offers a single revoke action; the Rust port matches
//! that surface.
//!
//! No real-time channel here — the device list mutates only when
//! the operator pairs (out-of-band CLI flow) or revokes (this page),
//! so a manual reload on mutation is sufficient.

use dioxus::prelude::*;

use crate::components::admin::{AdminPageHeader, StatusPill};
use crate::components::core::{Button, ButtonSize, ButtonVariant};
use crate::server_fns::admin::devices::{list_devices, revoke_device, DeviceRow};

#[component]
pub fn Devices() -> Element {
    let mut reload_token = use_signal(|| 0_u64);
    let devices = use_resource(move || {
        let _ = reload_token.read();
        async move { list_devices().await }
    });

    rsx! {
        div { class: "max-w-4xl mx-auto",
            AdminPageHeader {
                title: "Paired devices".to_string(),
                subtitle: Some(
                    "Mydia player apps paired to this instance over the p2p mesh.".to_string(),
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

            section { class: "card bg-base-100 shadow",
                div { class: "card-body",
                    match &*devices.read_unchecked() {
                        Some(Ok(rows)) if rows.is_empty() => rsx! {
                            div { id: "admin-devices-empty", class: "text-sm text-base-content/60 py-12 text-center",
                                "No paired devices. Pair a player from the mobile app to add one."
                            }
                        },
                        Some(Ok(rows)) => rsx! {
                            div { class: "overflow-x-auto",
                                table { class: "table",
                                    thead {
                                        tr {
                                            th { "Device" }
                                            th { "Status" }
                                            th { "Last seen" }
                                            th { class: "text-right", "Actions" }
                                        }
                                    }
                                    tbody { id: "admin-devices-rows",
                                        for row in rows.iter().cloned() {
                                            DeviceRowView {
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
                            div { class: "alert alert-error",
                                "Failed to load devices: {err}"
                            }
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
struct DeviceRowProps {
    row: DeviceRow,
    on_changed: Callback<()>,
}

#[component]
fn DeviceRowView(props: DeviceRowProps) -> Element {
    let mut acting = use_signal(|| false);
    let id_for_revoke = props.row.id.clone();
    let on_changed = props.on_changed;

    let on_revoke = move |_| {
        if *acting.read() {
            return;
        }
        acting.set(true);
        let id = id_for_revoke.clone();
        spawn(async move {
            if let Err(err) = revoke_device(id).await {
                tracing::warn!(%err, "revoke_device failed");
            }
            on_changed.call(());
            acting.set(false);
        });
    };

    let status = props.row.status.clone();
    let is_revoked = props.row.revoked_at.is_some();
    let last_seen = props
        .row
        .last_seen_at
        .clone()
        .unwrap_or_else(|| "Never".to_owned());

    rsx! {
        tr {
            td {
                div { class: "font-medium", "{props.row.device_name}" }
                div { class: "text-xs text-base-content/60 capitalize", "{props.row.platform}" }
            }
            td { StatusPill { status: status } }
            td { class: "text-sm", "{last_seen}" }
            td { class: "text-right whitespace-nowrap",
                Button {
                    variant: ButtonVariant::Error,
                    size: ButtonSize::Sm,
                    disabled: is_revoked || *acting.read(),
                    loading: *acting.read(),
                    onclick: on_revoke,
                    "Revoke"
                }
            }
        }
    }
}
