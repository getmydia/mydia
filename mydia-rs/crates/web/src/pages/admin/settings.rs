//! Admin → Configuration → Settings page.
//!
//! Phoenix counterpart: `MydiaWeb.AdminSettingsLive.Index`. Lays
//! every UI-exposed setting out as a row inside its category
//! card, with a source pill (`default` / `env` / `database`) and
//! an inline editor. Saves go through the [`update_setting`]
//! server fn one row at a time — the Phoenix page submits a whole
//! category at once but the row-level shape is simpler in the
//! Dioxus signal world and keeps the validation surface tighter.

use dioxus::prelude::*;

use crate::components::admin::{ConfigRow, ConfigSection, ConfigSource};
use crate::components::core::{Button, ButtonSize, ButtonVariant, Input};
use crate::server_fns::admin::settings::{
    list_settings, update_setting, ConfigSettingRow, SettingsSnapshot, UpdateSetting,
};

#[component]
pub fn Settings() -> Element {
    let mut reload_token = use_signal(|| 0_u64);
    let snapshot = use_resource(move || {
        let _ = reload_token.read();
        async move { list_settings().await }
    });

    // Page-level header lives in `AdminConfigShell`. Per-tab chrome is
    // just the action bar.
    rsx! {
        div { class: "max-w-5xl mx-auto",
            div { class: "flex justify-end mb-4",
                Button {
                    variant: ButtonVariant::Ghost,
                    size: ButtonSize::Sm,
                    onclick: move |_| reload_token.with_mut(|t| *t += 1),
                    "Refresh"
                }
            }

            match &*snapshot.read_unchecked() {
                Some(Ok(snap)) => rsx! {
                    SettingsBody {
                        snapshot: snap.clone(),
                        on_changed: move |()| reload_token.with_mut(|t| *t += 1),
                    }
                },
                Some(Err(err)) => rsx! {
                    div { class: "alert alert-error", "Failed to load settings: {err}" }
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
struct SettingsBodyProps {
    snapshot: SettingsSnapshot,
    on_changed: EventHandler<()>,
}

#[component]
fn SettingsBody(props: SettingsBodyProps) -> Element {
    rsx! {
        for category in props.snapshot.categories.iter().cloned() {
            CategoryCard {
                key: "{category.name}",
                category_name: category.name.clone(),
                rows: category.rows.clone(),
                on_changed: props.on_changed,
            }
        }
    }
}

#[derive(Props, Clone, PartialEq)]
struct CategoryCardProps {
    category_name: String,
    rows: Vec<ConfigSettingRow>,
    on_changed: EventHandler<()>,
}

#[component]
fn CategoryCard(props: CategoryCardProps) -> Element {
    let category_name = props.category_name.clone();
    let on_changed = props.on_changed;
    rsx! {
        ConfigSection {
            id: format!("admin-settings-{}", section_slug(&category_name)),
            title: category_name.clone(),
            for row in props.rows.iter().cloned() {
                SettingRowView {
                    key: "{row.key}",
                    row: row,
                    on_changed: on_changed,
                }
            }
        }
    }
}

fn section_slug(name: &str) -> String {
    name.to_ascii_lowercase()
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect()
}

#[derive(Props, Clone, PartialEq)]
struct SettingRowProps {
    row: ConfigSettingRow,
    on_changed: EventHandler<()>,
}

#[component]
fn SettingRowView(props: SettingRowProps) -> Element {
    let row = props.row.clone();
    let on_changed = props.on_changed;

    let mut draft = use_signal(|| row.value.clone());
    let mut acting = use_signal(|| false);
    let mut error: Signal<Option<String>> = use_signal(|| None);
    let mut saved_at: Signal<Option<String>> = use_signal(|| None);

    // Reset the draft when the row's effective value changes (e.g.
    // after a successful save somewhere else on the page reloads
    // the snapshot).
    use_effect({
        let value = row.value.clone();
        move || {
            draft.set(value.clone());
        }
    });

    let source = match row.source.as_str() {
        "env" => ConfigSource::Env,
        "database" => ConfigSource::Database,
        _ => ConfigSource::Default,
    };
    let is_env_locked = source == ConfigSource::Env;

    let row_for_submit = row.clone();
    let submit = move |_| {
        if *acting.read() || is_env_locked {
            return;
        }
        acting.set(true);
        error.set(None);

        let payload = UpdateSetting {
            key: row_for_submit.key.clone(),
            category: row_for_submit.category.clone(),
            value: draft.read().clone(),
        };
        spawn(async move {
            match update_setting(payload).await {
                Ok(_) => {
                    saved_at.set(Some("saved".to_owned()));
                    on_changed.call(());
                }
                Err(err) => error.set(Some(err.to_string())),
            }
            acting.set(false);
        });
    };

    let widget = build_widget(&row, draft, is_env_locked);

    rsx! {
        ConfigRow {
            label: row.label.clone(),
            description: row.description.clone(),
            source: Some(source),
            div { class: "flex flex-col gap-2",
                div { class: "flex flex-col sm:flex-row sm:items-end gap-2",
                    div { class: "flex-1", {widget} }
                    if !is_env_locked {
                        Button {
                            variant: ButtonVariant::Primary,
                            size: ButtonSize::Sm,
                            onclick: submit,
                            loading: *acting.read(),
                            "Save"
                        }
                    } else {
                        span { class: "text-xs text-base-content/60 sm:ml-2",
                            "Locked by env var"
                        }
                    }
                }
                if let Some(err) = error.read().clone() {
                    p { class: "text-sm text-error", "{err}" }
                }
                if saved_at.read().is_some() {
                    p { class: "text-xs text-success", "Saved" }
                }
            }
        }
    }
}

fn build_widget(row: &ConfigSettingRow, mut draft: Signal<String>, disabled: bool) -> Element {
    match row.kind.as_str() {
        "boolean" => {
            let checked = matches!(
                draft.read().to_ascii_lowercase().as_str(),
                "true" | "1" | "yes" | "on"
            );
            rsx! {
                Input {
                    name: row.key.clone(),
                    r#type: "checkbox".to_string(),
                    label: Some(if checked { "Enabled".to_string() } else { "Disabled".to_string() }),
                    checked: checked,
                    disabled: disabled,
                    onchange: move |evt: FormEvent| {
                        // Dioxus checkboxes deliver `"true"` / `"false"`.
                        let on = matches!(
                            evt.value().to_ascii_lowercase().as_str(),
                            "true" | "1" | "yes" | "on"
                        );
                        draft.set(if on { "true".to_owned() } else { "false".to_owned() });
                    },
                }
            }
        }
        "integer" => {
            let value = draft.read().clone();
            rsx! {
                Input {
                    name: row.key.clone(),
                    r#type: "number".to_string(),
                    value: value,
                    placeholder: row.placeholder.clone(),
                    disabled: disabled,
                    oninput: move |evt: FormEvent| draft.set(evt.value()),
                }
            }
        }
        _ => {
            let value = draft.read().clone();
            rsx! {
                Input {
                    name: row.key.clone(),
                    r#type: "text".to_string(),
                    value: value,
                    placeholder: row.placeholder.clone(),
                    disabled: disabled,
                    oninput: move |evt: FormEvent| draft.set(evt.value()),
                }
            }
        }
    }
}
