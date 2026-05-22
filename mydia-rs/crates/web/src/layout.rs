//! Top-level layout component.
//!
//! Structural mirror of `lib/mydia_web/components/layouts.ex`'s `app/1`
//! — `DaisyUI` drawer with `lg:drawer-open`, a mobile navbar with a
//! hamburger toggle, a sidebar with library/admin sections, and a
//! content area that renders the active route via `Outlet::<Route>`.
//!
//! Navigation data (movie/tv/downloads counts, current user, etc.)
//! flows through here in later units via context providers populated
//! by the U24 auth boundary. U22 ships an inert sidebar so the chrome
//! is visible on the hello page without depending on data plumbing
//! that isn't wired yet.

use dioxus::prelude::*;

use crate::components::core::Icon;
use crate::routes::Route;

#[component]
pub fn AppShell() -> Element {
    rsx! {
        div { class: "drawer lg:drawer-open",
            input { id: "main-drawer", r#type: "checkbox", class: "drawer-toggle" }

            // Content column — mobile navbar + main outlet
            div { class: "drawer-content flex flex-col",
                MobileNavbar {}
                main { class: "flex-1 p-4 lg:p-8 min-h-screen bg-base-200",
                    Outlet::<Route> {}
                }
            }

            // Sidebar — visible at lg+, drawer on mobile
            Sidebar {}
        }
    }
}

#[component]
fn MobileNavbar() -> Element {
    rsx! {
        header { class: "lg:hidden navbar bg-base-300 border-b border-base-content/10",
            div { class: "flex-none",
                label {
                    r#for: "main-drawer",
                    class: "btn btn-square btn-ghost",
                    aria_label: "Open menu",
                    Icon { name: "menu", class: "w-6 h-6" }
                }
            }
            div { class: "flex-1 px-2 font-semibold", "mydia" }
        }
    }
}

#[component]
fn Sidebar() -> Element {
    rsx! {
        div { class: "drawer-side z-30",
            label {
                r#for: "main-drawer",
                aria_label: "close sidebar",
                class: "drawer-overlay"
            }
            aside { class: "min-h-full w-64 bg-base-300 text-base-content border-r border-base-content/10 flex flex-col",
                div { class: "px-4 py-4 border-b border-base-content/10",
                    Link {
                        to: Route::Home {},
                        class: "text-xl font-bold tracking-tight hover:text-primary transition-colors",
                        "mydia"
                    }
                }
                nav { class: "flex-1 overflow-y-auto px-2 py-2",
                    ul { class: "menu menu-md",
                        li {
                            Link { to: Route::Home {},
                                Icon { name: "home", class: "w-5 h-5" }
                                "Home"
                            }
                        }
                        li {
                            Link {
                                to: Route::Hello { name: "world".into() },
                                Icon { name: "sparkles", class: "w-5 h-5" }
                                "Hello"
                            }
                        }
                        li {
                            Link {
                                to: Route::LibraryPaths {},
                                Icon { name: "home", class: "w-5 h-5" }
                                "Library paths"
                            }
                        }
                    }
                }
                div { class: "px-4 py-3 border-t border-base-content/10 text-xs opacity-60",
                    "U22 scaffolding — sidebar fills out in U24+"
                }
            }
        }
    }
}
