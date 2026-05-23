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

use crate::layout::{AppShell, AuthShell};
use crate::pages::activity::Activity;
use crate::pages::add_media::AddMedia;
use crate::pages::admin::devices::Devices;
use crate::pages::admin::jobs::Jobs;
use crate::pages::admin::library_paths::LibraryPaths;
use crate::pages::admin::requests::Requests;
use crate::pages::admin::transcodes::Transcodes;
use crate::pages::admin::users::Users;
use crate::pages::auth::login::Login;
use crate::pages::auth::setup::Setup;
use crate::pages::calendar::Calendar;
use crate::pages::dashboard::Dashboard;
use crate::pages::discover::Discover;
use crate::pages::downloads::Downloads;
use crate::pages::hello::Hello;
use crate::pages::import_media::ImportMedia;
use crate::pages::media::index::{Movies, TvShows};
use crate::pages::media::show::MediaShow;
use crate::pages::my_requests::MyRequests;
use crate::pages::profile::Profile;
use crate::pages::request_media::{RequestMovie, RequestSeries};

#[derive(Clone, Routable, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[rustfmt::skip]
pub enum Route {
    // Auth pages live outside the AppShell so an unauthenticated
    // user can reach /login and /setup without being bounced.
    #[layout(AuthShell)]
        #[route("/login")]
        Login {},

        #[route("/setup")]
        Setup {},

    #[end_layout]

    #[layout(AppShell)]
        // U24.e — dashboard replaces the U22 placeholder Home page.
        #[route("/")]
        Dashboard {},

        #[route("/hello/:name")]
        Hello { name: String },

        // U24.d — profile and account settings.
        #[route("/profile")]
        Profile {},

        // U24.f — TMDB curated discover grid.
        #[route("/discover")]
        Discover {},

        // U25.a — paginated movie and TV grids.
        #[route("/movies")]
        Movies {},

        #[route("/tv")]
        TvShows {},

        // U25.b — media detail page.
        #[route("/media/:id")]
        MediaShow { id: String },

        // U23 pilot — admin library paths.
        #[route("/admin/library_paths")]
        LibraryPaths {},

        // U28 — operational admin slice.
        #[route("/admin/jobs")]
        Jobs {},

        #[route("/admin/transcodes")]
        Transcodes {},

        #[route("/admin/users")]
        Users {},

        #[route("/admin/devices")]
        Devices {},

        #[route("/admin/requests")]
        Requests {},

        // U27 — operational user-facing pages.
        #[route("/calendar")]
        Calendar {},

        #[route("/activity")]
        Activity {},

        #[route("/downloads")]
        Downloads {},

        #[route("/add")]
        AddMedia {},

        #[route("/import")]
        ImportMedia {},

        #[route("/request/movie")]
        RequestMovie {},

        #[route("/request/series")]
        RequestSeries {},

        #[route("/requests")]
        MyRequests {},
}
