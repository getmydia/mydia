//! Dioxus root component — mounts the asset bundle and the router.
//!
//! Per Dioxus 0.7 conventions, CSS referenced via `asset!()` is
//! const-evaluated and registered into binary metadata; the `dx` CLI
//! copies the file into the bundle with a hashed filename. At runtime
//! `document::Stylesheet { href: APP_CSS }` emits a `<link>` tag in
//! `<head>` so the same file is served from the hashed path the bundle
//! exposes.

use dioxus::prelude::*;

use crate::routes::Route;

const APP_CSS: Asset = asset!("/assets/app.css");
const FAVICON: Asset = asset!("/assets/favicon.ico");

#[component]
pub fn App() -> Element {
    rsx! {
        document::Link { rel: "icon", href: FAVICON }
        document::Stylesheet { href: APP_CSS }
        document::Meta { name: "viewport", content: "width=device-width, initial-scale=1, viewport-fit=cover" }
        document::Meta { name: "theme-color", content: "#3b82f6" }
        document::Title { "mydia" }
        Router::<Route> {}
    }
}
