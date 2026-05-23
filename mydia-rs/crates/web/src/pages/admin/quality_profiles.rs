//! Admin → Configuration → Quality profiles page.
//!
//! Phoenix counterpart: `MydiaWeb.AdminQualityProfilesLive` plus
//! `MydiaWeb.AdminQualityProfileFormLive`. The Phoenix version
//! supports a forms-driving-forms shape — a profile is an ordered
//! list of cutoff items with their own resolution/codec/source
//! selectors.
//!
//! U28 follow-up ships a read-only list: page mounts, surfaces
//! profile names + cutoff counts, and points operators at the
//! follow-up needed to ship full CRUD. The
//! [`crate::components::admin::config_form`] primitive doesn't yet
//! support nested-form arrays; promoting it is U28-followup work.
//!
//! TODO(U28-followup): port the cutoff-item editor from
//! `MydiaWeb.AdminQualityProfileFormLive`. The nested-form pattern
//! likely needs a dedicated `QualityCutoffEditor` `LiveComponent`
//! analog (signal vector + reorder/insert/delete callbacks); kept
//! out of this slice to keep the diff reviewable.

use dioxus::prelude::*;

use crate::components::admin::{AdminPageHeader, ConfigSection};
use crate::components::core::{Button, ButtonSize, ButtonVariant};
use crate::server_fns::admin::quality_profiles::{list_quality_profiles, QualityProfileRow};

#[component]
pub fn QualityProfiles() -> Element {
    let mut reload_token = use_signal(|| 0_u64);
    let profiles = use_resource(move || {
        let _ = reload_token.read();
        async move { list_quality_profiles().await }
    });

    rsx! {
        div { class: "max-w-5xl mx-auto",
            AdminPageHeader {
                title: "Quality profiles".to_string(),
                subtitle: Some(
                    "Ordered cutoff rules deciding which release qualities mydia accepts."
                        .to_string(),
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

            div { class: "alert alert-info mb-6",
                div { class: "flex flex-col gap-1",
                    div { class: "font-semibold", "Profile editing is a follow-up" }
                    p { class: "text-sm",
                        "Quality profiles have nested cutoff items that don't fit the shared "
                        "config-form primitive yet. Use the seeded defaults or edit via SQL / CLI "
                        "until the inline editor ships."
                    }
                }
            }

            ConfigSection {
                id: "admin-quality-profiles".to_string(),
                title: "Profiles".to_string(),
                match &*profiles.read_unchecked() {
                    Some(Ok(rows)) => {
                        if rows.is_empty() {
                            rsx! {
                                div { id: "admin-quality-profiles-empty", class: "text-sm text-base-content/60 py-12 text-center",
                                    "No quality profiles configured yet."
                                }
                            }
                        } else {
                            let rows = rows.clone();
                            rsx! {
                                div { class: "overflow-x-auto",
                                    table { class: "table",
                                        thead {
                                            tr {
                                                th { "Name" }
                                                th { "Cutoff items" }
                                                th { "Created" }
                                            }
                                        }
                                        tbody { id: "admin-quality-profiles-rows",
                                            for row in rows.into_iter() {
                                                ProfileRowView {
                                                    key: "{row.id}",
                                                    row: row,
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    Some(Err(err)) => rsx! {
                        div { class: "alert alert-error", "Failed to load profiles: {err}" }
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
struct ProfileRowProps {
    row: QualityProfileRow,
}

#[component]
fn ProfileRowView(props: ProfileRowProps) -> Element {
    let created = props
        .row
        .inserted_at
        .clone()
        .unwrap_or_else(|| "—".to_owned());
    rsx! {
        tr {
            td { class: "font-medium", "{props.row.name}" }
            td { "{props.row.cutoff_count}" }
            td { class: "text-xs", "{created}" }
        }
    }
}
