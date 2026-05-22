//! Hello page — Dioxus router smoke page.
//!
//! Renders the dynamic path param so we can observe the router
//! resolving `/hello/:name` correctly on both SSR and client-side
//! navigation.

use dioxus::prelude::*;

use crate::components::core::Icon;
use crate::routes::Route;

#[component]
pub fn Hello(name: String) -> Element {
    rsx! {
        div { class: "max-w-3xl mx-auto",
            div { class: "card bg-base-100 shadow",
                div { class: "card-body",
                    h1 { class: "card-title text-3xl",
                        Icon { name: "sparkles".to_string(), class: "w-7 h-7 text-primary".to_string() }
                        "Hello, {name}!"
                    }
                    p { class: "text-base-content/70",
                        "Dioxus 0.7 router resolved a dynamic path param. \
                         Hydration runs after the wasm bundle loads."
                    }
                    div { class: "card-actions justify-end mt-2",
                        Link {
                            to: Route::Home {},
                            class: "btn btn-ghost",
                            "Back home"
                        }
                    }
                }
            }
        }
    }
}
