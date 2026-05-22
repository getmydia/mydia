//! Home page — placeholder until U24 lands the real dashboard.

use dioxus::prelude::*;

use crate::components::core::{Button, ButtonSize, ButtonVariant, Icon};
use crate::routes::Route;

#[component]
pub fn Home() -> Element {
    rsx! {
        div { class: "max-w-3xl mx-auto",
            header { class: "mb-6",
                h1 { class: "text-3xl font-bold tracking-tight", "mydia-rs" }
                p { class: "mt-2 text-base-content/70",
                    "Rust reimplementation of the Phoenix backend. \
                     U22 brings up the Dioxus full-stack scaffolding; \
                     real pages land in U23-U28."
                }
            }

            div { class: "card bg-base-100 shadow",
                div { class: "card-body",
                    h2 { class: "card-title",
                        Icon { name: "sparkles".to_string(), class: "w-5 h-5".to_string() }
                        "Smoke test"
                    }
                    p {
                        "If you can see this, SSR is working. Try the link below — \
                         intra-app navigation should not full-page reload once the \
                         wasm bundle is hydrated."
                    }
                    div { class: "card-actions justify-end mt-2",
                        Link {
                            to: Route::Hello { name: "mydia".into() },
                            class: "btn btn-primary",
                            "Say hello"
                        }
                    }
                }
            }

            div { class: "mt-6 flex flex-wrap gap-2",
                Button {
                    variant: ButtonVariant::Primary,
                    size: ButtonSize::Md,
                    "Primary"
                }
                Button {
                    variant: ButtonVariant::Secondary,
                    "Secondary"
                }
                Button {
                    variant: ButtonVariant::Ghost,
                    "Ghost"
                }
                Button {
                    variant: ButtonVariant::Outline,
                    "Outline"
                }
                Button {
                    variant: ButtonVariant::Error,
                    "Error"
                }
            }
        }
    }
}
