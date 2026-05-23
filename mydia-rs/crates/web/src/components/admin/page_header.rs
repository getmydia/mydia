//! Standard admin page header — title, optional subtitle, optional
//! action slot rendered on the right.
//!
//! Phoenix counterpart: the `<.header>` block at the top of every
//! `admin_*_live/index.html.heex`. Kept here so the admin pages don't
//! each reinvent the same flex/space-y wrapper.

use dioxus::prelude::*;

#[derive(Props, Clone, PartialEq)]
pub struct AdminPageHeaderProps {
    pub title: String,
    #[props(default)]
    pub subtitle: Option<String>,
    /// Right-aligned actions (typically buttons or filter selects).
    #[props(default)]
    pub actions: Option<Element>,
}

#[component]
pub fn AdminPageHeader(props: AdminPageHeaderProps) -> Element {
    rsx! {
        header { class: "flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between mb-6",
            div {
                h1 { class: "text-2xl font-bold", "{props.title}" }
                if let Some(sub) = props.subtitle.as_ref() {
                    p { class: "text-sm text-base-content/70", "{sub}" }
                }
            }
            if let Some(actions) = props.actions {
                div { class: "flex items-center gap-2", {actions} }
            }
        }
    }
}
