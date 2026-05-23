//! Import media — match unmatched library files to TMDB/TVDB metadata.
//!
//! Phoenix counterpart: `MydiaWeb.ImportMediaLive.Index` — the largest
//! `LiveView` in the codebase (~4.7k LOC) covering a search → match →
//! finalize flow with custom file-grouping heuristics, season/episode
//! pickers, and bulk renaming controls.
//!
//! U27 ships a deliberate placeholder: the route exists, the sidebar
//! links here, and the page surfaces what the operator should expect
//! once the full flow is ported. Splitting that 4.7k LOC across
//! follow-up units (see TODOs below) is on the U27 docket and tracked
//! via the planning doc; the placeholder unblocks the rest of the
//! operational pages without forcing a megamerge.
//!
//! TODO(U27.import-search-step): port the unmatched-file scanner +
//! TMDB/TVDB candidate search.
//! TODO(U27.import-match-step): per-file association picker (which
//! season, which episode, which release year).
//! TODO(U27.import-finalize-step): hardlink / move plan + rename
//! preview, then commit + persist.

use dioxus::prelude::*;

use crate::components::admin::AdminPageHeader;

#[component]
pub fn ImportMedia() -> Element {
    rsx! {
        div { class: "max-w-3xl mx-auto",
            AdminPageHeader {
                title: "Import library".to_string(),
                subtitle: Some(
                    "Match files in your library to TMDB / TVDB metadata. Coming soon.".to_string(),
                ),
                actions: None,
            }

            section { class: "card bg-base-100 shadow",
                div { id: "import-media-placeholder", class: "card-body items-center text-center py-12",
                    div { class: "text-5xl mb-3 opacity-30", "📂" }
                    h2 { class: "card-title", "Import not available yet" }
                    p { class: "text-sm text-base-content/70 max-w-md",
                        "The library import flow is being ported step by step. For now, use the metadata-relay search on the Add media page to bring titles into your library."
                    }
                    p { class: "text-xs text-base-content/50",
                        "Track progress in the U27 follow-ups: search step, match step, finalize step."
                    }
                }
            }
        }
    }
}
