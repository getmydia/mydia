//! Configuration form primitives for the admin pages.
//!
//! Phoenix counterpart: the section-card pattern used by
//! `admin_settings_live`, `admin_system_live`, and the various
//! config sub-pages (download clients, indexers, media servers,
//! remote access, release blacklist). Every config page is a stack
//! of cards, each one a labelled section grouping a handful of
//! key/value rows. The rows render different widgets — boolean
//! toggles, integer inputs, string inputs, selects — but the chrome
//! (card with header, body, optional save button, optional source
//! pill) is identical.
//!
//! This module ships three small pieces:
//!
//! - [`ConfigSection`] — the card wrapper with title + optional
//!   description, optional source pill, and a `children` slot for the
//!   actual rows.
//! - [`ConfigRow`] — a single labelled row. Just a `<label>` on the
//!   left and a slot on the right. Pages render an `<Input>` (or a
//!   custom widget) into the slot.
//! - [`SourcePill`] — small badge marking a value's origin
//!   (`env`, `database`, `default`). Settings + system surfaces both
//!   render it.
//!
//! The primitive is intentionally render-only — no validation, no
//! state management. Validation lives in the server fn; form state
//! lives in the page's signals. Mirroring Phoenix discipline: forms
//! are composed of small, predictable primitives, not magic `LiveForm`
//! containers.

use dioxus::prelude::*;

// ---------- Source ----------

/// Where a configuration value's effective answer came from. Used
/// by the system + settings pages to surface override precedence.
#[derive(Default, Clone, PartialEq, Eq, Copy, Debug)]
pub enum ConfigSource {
    /// Hard-coded fallback in the schema.
    #[default]
    Default,
    /// Read from `MYDIA_*` / `OIDC_*` environment variables.
    Env,
    /// Read from the `config_settings` table.
    Database,
}

impl ConfigSource {
    /// `DaisyUI` badge class. Env wins are highlighted as `info` to
    /// signal "this is locked at the process layer."
    #[must_use]
    pub fn badge_class(self) -> &'static str {
        match self {
            Self::Default => "badge-ghost",
            Self::Env => "badge-info",
            Self::Database => "badge-primary",
        }
    }

    /// Short human label.
    #[must_use]
    pub fn label(self) -> &'static str {
        match self {
            Self::Default => "default",
            Self::Env => "env",
            Self::Database => "database",
        }
    }
}

#[derive(Props, Clone, PartialEq, Eq)]
pub struct SourcePillProps {
    pub source: ConfigSource,
    #[props(default)]
    pub class: String,
}

#[component]
pub fn SourcePill(props: SourcePillProps) -> Element {
    let class = props.source.badge_class();
    let label = props.source.label();
    let extra = props.class.clone();
    rsx! {
        span { class: "badge badge-xs {class} {extra}", "{label}" }
    }
}

// ---------- Section ----------

#[derive(Props, Clone, PartialEq)]
pub struct ConfigSectionProps {
    pub title: String,
    #[props(default)]
    pub description: Option<String>,
    /// Optional `<id>` for the surrounding card — useful in tests so
    /// `has_element?` selectors stay stable.
    #[props(default)]
    pub id: Option<String>,
    /// Optional action slot rendered top-right (typically a "Save" or
    /// "Test connection" button).
    #[props(default)]
    pub actions: Option<Element>,
    /// Body content — pages render `ConfigRow` instances here, or
    /// arbitrary `rsx!` for custom layouts.
    pub children: Element,
}

/// Card-style section wrapper. Mirrors the
/// `<.card><.card_body>` block at the top of every Phoenix admin
/// config sub-page.
#[component]
pub fn ConfigSection(props: ConfigSectionProps) -> Element {
    let id = props.id.clone().unwrap_or_default();
    rsx! {
        section {
            id: "{id}",
            class: "card bg-base-100 shadow mb-6",
            div { class: "card-body",
                header { class: "flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between mb-4",
                    div {
                        h2 { class: "card-title text-lg", "{props.title}" }
                        if let Some(desc) = props.description.as_ref() {
                            p { class: "text-sm text-base-content/70 mt-1", "{desc}" }
                        }
                    }
                    if let Some(actions) = props.actions {
                        div { class: "flex items-center gap-2", {actions} }
                    }
                }
                {props.children}
            }
        }
    }
}

// ---------- Row ----------

#[derive(Props, Clone, PartialEq)]
pub struct ConfigRowProps {
    pub label: String,
    #[props(default)]
    pub description: Option<String>,
    /// Optional source pill rendered next to the label.
    #[props(default)]
    pub source: Option<ConfigSource>,
    /// Right-hand widget — typically an `<Input>` instance or a
    /// custom render. Required.
    pub children: Element,
}

/// One labelled key/value row. The label + description sit on the
/// left, the widget on the right. Layout collapses to stacked on
/// small viewports so long input fields don't overflow.
#[component]
pub fn ConfigRow(props: ConfigRowProps) -> Element {
    rsx! {
        div { class: "grid grid-cols-1 sm:grid-cols-3 gap-3 py-3 border-b border-base-content/10 last:border-b-0",
            div { class: "sm:col-span-1",
                div { class: "flex items-center gap-2",
                    label { class: "text-sm font-medium", "{props.label}" }
                    if let Some(src) = props.source {
                        SourcePill { source: src }
                    }
                }
                if let Some(desc) = props.description.as_ref() {
                    p { class: "text-xs text-base-content/60 mt-1", "{desc}" }
                }
            }
            div { class: "sm:col-span-2",
                {props.children}
            }
        }
    }
}

// ---------- Read-only stat row ----------

#[derive(Props, Clone, PartialEq, Eq)]
pub struct StatRowProps {
    pub label: String,
    pub value: String,
    #[props(default)]
    pub hint: Option<String>,
}

/// Read-only key/value pair for the system status surface. No
/// input widget — just two columns of text with optional tooltip.
#[component]
pub fn StatRow(props: StatRowProps) -> Element {
    rsx! {
        div { class: "grid grid-cols-2 gap-3 py-2 text-sm border-b border-base-content/10 last:border-b-0",
            div { class: "text-base-content/70", "{props.label}" }
            div { class: "font-mono text-right",
                "{props.value}"
                if let Some(hint) = props.hint.as_ref() {
                    span { class: "ml-2 text-xs text-base-content/60", "{hint}" }
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn source_badge_classes_map_to_daisyui() {
        assert_eq!(ConfigSource::Default.badge_class(), "badge-ghost");
        assert_eq!(ConfigSource::Env.badge_class(), "badge-info");
        assert_eq!(ConfigSource::Database.badge_class(), "badge-primary");
    }

    #[test]
    fn source_label_matches_phoenix_vocab() {
        assert_eq!(ConfigSource::Default.label(), "default");
        assert_eq!(ConfigSource::Env.label(), "env");
        assert_eq!(ConfigSource::Database.label(), "database");
    }
}
