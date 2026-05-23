//! Dioxus root component — mounts the asset bundle and the router.
//!
//! Per Dioxus 0.7 conventions, CSS referenced via `asset!()` is
//! const-evaluated and registered into binary metadata; the `dx` CLI
//! copies the file into the bundle with a hashed filename. At runtime
//! `document::Stylesheet { href: APP_CSS }` emits a `<link>` tag in
//! `<head>` so the same file is served from the hashed path the bundle
//! exposes.
//!
//! The CSS asset path points at `tailwind.built.css`, NOT the
//! `tailwind.css` source. The source is Tailwind v4 + `DaisyUI`
//! directives that the browser can't parse; dx auto-runs the
//! standalone `tailwindcss` binary (configured via `[application]
//! tailwind_input` / `tailwind_output` in `Dioxus.toml`) to compile
//! it into the `.built.css` file the asset macro picks up. `dx
//! serve` watches and rebuilds on save; `dx build` runs it once.
//!
//! A placeholder `tailwind.built.css` ships in the repo so `cargo
//! build` (outside dx) can resolve the `asset!()` path on a fresh
//! checkout; the first `dx serve` / `dx build` overwrites it with
//! the real compiled CSS.

use dioxus::prelude::*;

use crate::routes::Route;

const APP_CSS: Asset = asset!("/assets/tailwind.built.css");
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
