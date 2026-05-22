//! Route enum mirroring the navigable Phoenix router surface.
//!
//! U22 ships a deliberately small enum — `Home` and `Hello` only —
//! sufficient to prove SSR + hydration + intra-app navigation work.
//! U23 (admin library paths pilot) is the first real route addition;
//! U24-U28 fill out the ~50 navigable routes from `lib/mydia_web/router.ex`.
//!
//! When you add a route here you also add a `#[route(...)]` attribute
//! and a `#[component] fn` rendering it in `pages/`. The router is
//! type-checked at compile time so a Link to a missing variant fails
//! the build.

use dioxus::prelude::*;
use serde::{Deserialize, Serialize};

use crate::layout::AppShell;
use crate::pages::admin::library_paths::LibraryPaths;
use crate::pages::{hello::Hello, home::Home};

#[derive(Clone, Routable, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[rustfmt::skip]
pub enum Route {
    #[layout(AppShell)]
        #[route("/")]
        Home {},

        #[route("/hello/:name")]
        Hello { name: String },

        // U23 pilot — admin library paths.
        #[route("/admin/library_paths")]
        LibraryPaths {},
}
