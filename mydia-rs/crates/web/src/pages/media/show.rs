//! `/media/:id` — detail page placeholder (U25.b, pending).
//!
//! U25.a renders a working "coming soon" panel so the grid cards have
//! a real navigation target. U25.b replaces this with the full detail
//! view (overview, seasons, episodes, file picker, play button).

use dioxus::prelude::*;

#[component]
pub fn MediaShow(id: String) -> Element {
    rsx! {
        div { class: "flex flex-col gap-4",
            h1 { class: "text-2xl font-bold tracking-tight", "Media detail" }
            div { class: "alert alert-info",
                span {
                    "The detail page is still being ported (U25.b). "
                    "You requested item "
                    code { class: "font-mono text-xs", "{id}" }
                    "."
                }
            }
        }
    }
}
