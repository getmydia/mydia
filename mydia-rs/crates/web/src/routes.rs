//! Route enum mirroring the navigable Phoenix router surface.
//!
//! U22 shipped a deliberately small enum — `Home` and `Hello` only —
//! sufficient to prove SSR + hydration + intra-app navigation work.
//! U23 (admin library paths pilot) was the first real route addition;
//! U24-U28 filled out the ~50 navigable routes from
//! `lib/mydia_web/router.ex`.
//!
//! Admin configuration tabs live under `/admin/config/*` and share an
//! `AdminConfigShell` layout that renders the "Configuration" h1, the
//! tab strip, and an outlet for the active tab. Mirrors Phoenix's
//! `AdminComponents.admin_page` chrome and the kebab-case URLs at
//! `lib/mydia_web/router.ex:187-195`. `/admin/config` itself redirects
//! to `/admin/config/status` (Phoenix's `RedirectController :admin_config`).
//!
//! When you add a route here you also add a `#[route(...)]` attribute
//! and a `#[component] fn` rendering it in `pages/`. The router is
//! type-checked at compile time so a Link to a missing variant fails
//! the build.

use dioxus::prelude::*;
use serde::{Deserialize, Serialize};

use crate::layout::{AdminConfigShell, AppShell, AuthShell};
use crate::pages::activity::Activity;
use crate::pages::add_media::AddMedia;
use crate::pages::admin::devices::Devices;
use crate::pages::admin::download_clients::DownloadClients;
use crate::pages::admin::import_lists::ImportLists;
use crate::pages::admin::indexers::Indexers;
use crate::pages::admin::jobs::Jobs;
use crate::pages::admin::library_paths::LibraryPaths;
use crate::pages::admin::media_servers::MediaServers;
use crate::pages::admin::quality_profiles::QualityProfiles;
use crate::pages::admin::release_blacklist::ReleaseBlacklist;
use crate::pages::admin::remote_access::RemoteAccess;
use crate::pages::admin::requests::Requests;
use crate::pages::admin::settings::Settings;
use crate::pages::admin::system::System;
use crate::pages::admin::transcodes::Transcodes;
use crate::pages::admin::users::Users;
use crate::pages::auth::login::Login;
use crate::pages::auth::setup::Setup;
use crate::pages::calendar::Calendar;
use crate::pages::collections::index::Collections;
use crate::pages::collections::show::CollectionShow;
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
use crate::pages::search::Search;

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

        // U26 — collections + library search.
        #[route("/collections")]
        Collections {},

        #[route("/collections/:id")]
        CollectionShow { id: String },

        #[route("/search")]
        Search {},

        // Admin standalone surfaces (kebab-case to match Phoenix's
        // `lib/mydia_web/router.ex:196-202`). Transcodes and Devices
        // stay routable as deep-links from Jobs / Users detail, but
        // they drop out of the sidebar.
        //
        // The `#[redirect]` for /admin/config piggy-backs on Jobs as
        // a host variant — the redirect path is independent of the
        // variant's own route, and the macro requires every
        // `#[redirect]` to be attached to a `#[route]` line. Mirrors
        // Phoenix's `RedirectController :admin_config` at
        // `lib/mydia_web/router.ex:173`.
        #[redirect("/admin/config", || Route::System {})]
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

        #[route("/admin/import-lists")]
        ImportLists {},

        #[route("/admin/release-blacklist")]
        ReleaseBlacklist {},

        // Configuration tabs — Phoenix's `RedirectController
        // :admin_config` (`router.ex:173`) bounces /admin/config to
        // the Status tab; that redirect is hosted on the Jobs variant
        // above so the path stays outside this nest.
        #[nest("/admin/config")]
            #[layout(AdminConfigShell)]
                #[route("/status")]
                System {},

                #[route("/settings")]
                Settings {},

                #[route("/quality")]
                QualityProfiles {},

                #[route("/clients")]
                DownloadClients {},

                #[route("/indexers")]
                Indexers {},

                #[route("/library-paths")]
                LibraryPaths {},

                #[route("/media-servers")]
                MediaServers {},

                #[route("/remote-access")]
                RemoteAccess {},
}
