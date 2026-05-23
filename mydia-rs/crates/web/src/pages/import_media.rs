//! Import media — search the metadata catalog for a candidate to
//! attach to the library.
//!
//! Phoenix counterpart: `MydiaWeb.ImportMediaLive.Index` (~4.7k LOC
//! across the `LiveView`, its components, and the matching pipeline).
//! The Rust port lands a deliberate three-step flow:
//!
//!   1. Search a title → candidates grid
//!   2. Pick a candidate → match-step detail card with disambiguating
//!      fields (year, runtime, country, alternative titles)
//!   3. Confirm → finalize writes the `media_items` row, optionally
//!      associates a file, and dispatches a metadata-refresh job.
//!
//! Step 1 lives in this commit. Steps 2 + 3 follow in the next two
//! commits behind the same page-level state machine.
//!
//! TODO(U27.import-followup): the Phoenix `LiveView` also surfaces
//! "skip", "blacklist", "manual rename", and a bulk
//! season-disambiguation picker. None of those land here; the
//! search → pick → finalize flow covers the operator's primary
//! workflow without doubling the modal's complexity.

use dioxus::prelude::*;

use crate::components::admin::{AdminPageHeader, FilterBar, FilterOption};
use crate::components::core::{Button, ButtonVariant, Input};
use crate::components::request_form::CandidateCard;
use crate::server_fns::add_media::AddMediaCandidate;
use crate::server_fns::import_media::{search_candidates, ImportCandidate, ImportSearchQuery};

const MEDIA_TYPE_OPTIONS: &[(&str, &str)] = &[("movie", "Movies"), ("tv_show", "TV Shows")];

/// One step in the page-level state machine. Slice 1 only ever holds
/// `Search`; the match + finalize steps unlock the other variants in
/// the next two commits.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Step {
    Search,
}

#[component]
pub fn ImportMedia() -> Element {
    // The step signal is the spine of the state machine; today it
    // never transitions because the match-step UI lands in the next
    // commit, but threading it through here keeps the page shape
    // stable across slices.
    let step = use_signal(|| Step::Search);
    let media_type = use_signal(|| "movie".to_owned());
    let query = use_signal(String::new);
    let mut submitted_query = use_signal(String::new);
    let last_error = use_signal::<Option<String>>(|| None);

    let results = use_resource(move || {
        let q = submitted_query.read().clone();
        let mt = media_type.read().clone();
        async move {
            if q.trim().is_empty() {
                Ok(Vec::new())
            } else {
                search_candidates(ImportSearchQuery {
                    query: q,
                    media_type: mt,
                })
                .await
            }
        }
    });

    let on_media_type = {
        let mut media_type = media_type;
        move |value: String| media_type.set(value)
    };

    let on_query_input = {
        let mut query = query;
        move |evt: FormEvent| query.set(evt.value())
    };

    let on_submit_search = move |evt: FormEvent| {
        evt.prevent_default();
        submitted_query.set(query.read().clone());
    };

    rsx! {
        div { class: "max-w-4xl mx-auto",
            AdminPageHeader {
                title: "Import library".to_string(),
                subtitle: Some(
                    "Search the metadata catalog for the title you want to import, then pick the best match."
                        .to_string(),
                ),
                actions: None,
            }

            match *step.read() {
                Step::Search => rsx! {
                    SearchStep {
                        media_type: media_type.read().clone(),
                        query: query.read().clone(),
                        submitted_query: submitted_query.read().clone(),
                        last_error: last_error.read().clone(),
                        results: results.read_unchecked().clone(),
                        on_media_type: on_media_type,
                        on_query_input: on_query_input,
                        on_submit: on_submit_search,
                    }
                },
            }
        }
    }
}

#[component]
fn SearchStep(
    media_type: String,
    query: String,
    submitted_query: String,
    last_error: Option<String>,
    results: Option<Result<Vec<ImportCandidate>, dioxus::fullstack::ServerFnError>>,
    on_media_type: Callback<String>,
    on_query_input: Callback<FormEvent>,
    on_submit: Callback<FormEvent>,
) -> Element {
    rsx! {
        div { class: "mb-3",
            FilterBar {
                current: media_type.clone(),
                options: MEDIA_TYPE_OPTIONS
                    .iter()
                    .map(|(v, l)| FilterOption::new(*v, *l))
                    .collect(),
                on_select: move |v: String| on_media_type.call(v),
            }
        }

        form {
            id: "import-media-search",
            class: "flex gap-2 mb-6",
            onsubmit: move |evt: FormEvent| on_submit.call(evt),
            div { class: "flex-1",
                Input {
                    name: "query".to_string(),
                    placeholder: Some("Search by title…".to_string()),
                    value: "{query}",
                    oninput: move |evt: FormEvent| on_query_input.call(evt),
                }
            }
            Button {
                variant: ButtonVariant::Primary,
                r#type: "submit".to_string(),
                "Search"
            }
        }

        if let Some(err) = last_error {
            div { class: "alert alert-error mb-4", "{err}" }
        }

        section { id: "import-media-results", class: "space-y-3",
            match &results {
                Some(Ok(items)) if items.is_empty() && submitted_query.is_empty() => rsx! {
                    div { id: "import-media-empty", class: "text-sm text-base-content/60 py-12 text-center",
                        "Enter a title above to search the metadata catalog."
                    }
                },
                Some(Ok(items)) if items.is_empty() => rsx! {
                    div { id: "import-media-no-results", class: "text-sm text-base-content/60 py-12 text-center",
                        "No results for that query."
                    }
                },
                Some(Ok(items)) => rsx! {
                    for candidate in items.iter().cloned() {
                        CandidateCard {
                            key: "{candidate.provider}-{candidate.external_id}",
                            candidate: to_card_candidate(&candidate),
                            cta_label: "Match".to_string(),
                            // TODO(U27.import-match-step): advance the
                            // state machine to `Step::Match { candidate }`
                            // here. Today the CTA is a no-op while the
                            // match-step UI lands in the next commit.
                            on_cta: Callback::new(|_: AddMediaCandidate| {}),
                            busy: false,
                            already_added: false,
                        }
                    }
                },
                Some(Err(err)) => rsx! {
                    div { class: "alert alert-error", "Search failed: {err}" }
                },
                None if !submitted_query.is_empty() => rsx! {
                    div { class: "py-8 text-center",
                        span { class: "loading loading-spinner loading-md" }
                    }
                },
                None => rsx! {
                    div { id: "import-media-empty", class: "text-sm text-base-content/60 py-12 text-center",
                        "Enter a title above to search the metadata catalog."
                    }
                },
            }
        }
    }
}

/// Bridge our `ImportCandidate` into the shared `AddMediaCandidate`
/// shape so the existing `CandidateCard` component renders without a
/// fork. The two structs carry the same fields; this just hands a
/// fresh allocation across the component boundary.
fn to_card_candidate(c: &ImportCandidate) -> AddMediaCandidate {
    AddMediaCandidate {
        provider: c.provider.clone(),
        external_id: c.external_id.clone(),
        title: c.title.clone(),
        original_title: c.original_title.clone(),
        year: c.year,
        overview: c.overview.clone(),
        poster_path: c.poster_path.clone(),
        release_date: c.release_date.clone(),
        media_type: c.media_type.clone(),
    }
}
