//! Horizontal filter pill bar — `(value, label)` options rendered as
//! a row of `btn-xs` toggles. Used by the requests page (filter by
//! status), the users page (filter by role), and the jobs page
//! (filter by state).
//!
//! Phoenix counterpart: the `phx-click="filter"` button rows in the
//! admin index templates. Component owns nothing of its own — the
//! parent page holds the selected value in a signal and re-renders.

use dioxus::prelude::*;

#[derive(Clone, PartialEq, Eq, Debug)]
pub struct FilterOption {
    pub value: String,
    pub label: String,
}

impl FilterOption {
    #[must_use]
    pub fn new(value: impl Into<String>, label: impl Into<String>) -> Self {
        Self {
            value: value.into(),
            label: label.into(),
        }
    }
}

#[derive(Props, Clone, PartialEq)]
pub struct FilterBarProps {
    /// Selected value. Equality against `option.value` decides which
    /// pill renders as "active".
    pub current: String,
    pub options: Vec<FilterOption>,
    /// Fired with the option's `value` when the operator clicks it.
    pub on_select: Callback<String>,
}

#[component]
pub fn FilterBar(props: FilterBarProps) -> Element {
    let current = props.current.clone();
    let on_select = props.on_select;

    rsx! {
        div { class: "flex flex-wrap items-center gap-2",
            for option in props.options.iter().cloned() {
                FilterPill {
                    key: "{option.value}",
                    option: option,
                    current: current.clone(),
                    on_select: on_select,
                }
            }
        }
    }
}

#[derive(Props, Clone, PartialEq)]
struct FilterPillProps {
    option: FilterOption,
    current: String,
    on_select: Callback<String>,
}

#[component]
fn FilterPill(props: FilterPillProps) -> Element {
    let is_active = props.option.value == props.current;
    let class = if is_active {
        "btn btn-xs btn-primary"
    } else {
        "btn btn-xs btn-ghost"
    };
    let value = props.option.value.clone();
    let on_select = props.on_select;

    rsx! {
        button {
            r#type: "button",
            class: "{class}",
            onclick: move |_| on_select.call(value.clone()),
            "{props.option.label}"
        }
    }
}
