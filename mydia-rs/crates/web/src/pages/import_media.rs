//! Import media — search the metadata catalog, pick a candidate,
//! confirm an import.
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
//! Steps 1 + 2 live in this file. Step 3 lands in the next commit
//! behind the same page-level state machine.
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
use crate::routes::Route;
use crate::server_fns::add_media::AddMediaCandidate;
use crate::server_fns::import_media::{
    fetch_candidate_details, finalize_import, search_candidates, ImportCandidate,
    ImportCandidateDetails, ImportCandidateRef, ImportFinalize, ImportSearchQuery,
};

const MEDIA_TYPE_OPTIONS: &[(&str, &str)] = &[("movie", "Movies"), ("tv_show", "TV Shows")];

/// One step in the page-level state machine. The `Search` variant
/// holds no extra data — query + media-type + result list are kept
/// in their own signals so the search results don't get lost when
/// the operator advances to the match step and back. The
/// `Match` variant carries the candidate the operator picked so the
/// match-step UI knows which detail card to render.
#[derive(Debug, Clone, PartialEq)]
enum Step {
    Search,
    Match { candidate: ImportCandidate },
}

#[component]
pub fn ImportMedia() -> Element {
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

    // Advance the state machine when the operator clicks "Match" on
    // a candidate card. The candidate is moved into the Step variant
    // so the match-step component can render the right detail card
    // without re-reading the search results.
    let on_pick_candidate = {
        let mut step = step;
        Callback::new(move |c: ImportCandidate| {
            step.set(Step::Match { candidate: c });
        })
    };

    let on_back_to_search = {
        let mut step = step;
        Callback::new(move |(): ()| {
            step.set(Step::Search);
        })
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

            match step.read().clone() {
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
                        on_pick: on_pick_candidate,
                    }
                },
                Step::Match { candidate } => rsx! {
                    MatchStep {
                        candidate: candidate,
                        on_back: on_back_to_search,
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
    on_pick: Callback<ImportCandidate>,
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
                Some(Ok(items)) => {
                    let candidates: Vec<ImportCandidate> = items.clone();
                    rsx! {
                        for candidate in candidates.into_iter() {
                            CandidateCard {
                                key: "{candidate.provider}-{candidate.external_id}",
                                candidate: to_card_candidate(&candidate),
                                cta_label: "Match".to_string(),
                                on_cta: {
                                    let picked = candidate.clone();
                                    let on_pick = on_pick;
                                    Callback::new(move |_: AddMediaCandidate| {
                                        on_pick.call(picked.clone());
                                    })
                                },
                                busy: false,
                                already_added: false,
                            }
                        }
                    }
                }
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

#[component]
fn MatchStep(candidate: ImportCandidate, on_back: Callback<()>) -> Element {
    // Fetch the full metadata for the chosen candidate. This is a
    // separate round-trip (rather than reusing the search result)
    // because the search payload only carries the fields the grid
    // renders; the detail card needs runtime, genres, country, and
    // alternative titles to help the operator disambiguate.
    let details = {
        let candidate = candidate.clone();
        use_resource(move || {
            let payload = ImportCandidateRef {
                provider: candidate.provider.clone(),
                external_id: candidate.external_id.clone(),
                media_type: candidate.media_type.clone(),
            };
            async move { fetch_candidate_details(payload).await }
        })
    };

    let candidate_for_fallback = candidate.clone();
    let candidate_for_confirm = candidate.clone();

    let nav = navigator();
    let mut submitting = use_signal(|| false);
    let mut finalize_error = use_signal::<Option<String>>(|| None);

    let on_confirm = {
        let candidate = candidate_for_confirm.clone();
        Callback::new(move |confirmed: ImportCandidateDetails| {
            if *submitting.read() {
                return;
            }
            submitting.set(true);
            finalize_error.set(None);
            // Use the freshly-fetched details when available — the
            // candidate fallback may carry a less canonical title
            // (e.g. localized vs. original) than the detail payload.
            let title = if confirmed.title.is_empty() {
                candidate.title.clone()
            } else {
                confirmed.title.clone()
            };
            let payload = ImportFinalize {
                provider: candidate.provider.clone(),
                external_id: candidate.external_id.clone(),
                media_type: candidate.media_type.clone(),
                title,
                year: confirmed.year.or(candidate.year),
                file_id: None,
                category_override: None,
            };
            spawn(async move {
                match finalize_import(payload).await {
                    Ok(ack) => {
                        nav.push(Route::MediaShow {
                            id: ack.media_item_id,
                        });
                    }
                    Err(err) => {
                        finalize_error.set(Some(err.to_string()));
                        submitting.set(false);
                    }
                }
            });
        })
    };

    rsx! {
        div { id: "import-media-match", class: "space-y-4",
            div { id: "import-media-back-row", class: "flex items-center gap-2",
                Button {
                    variant: ButtonVariant::Ghost,
                    disabled: *submitting.read(),
                    onclick: move |_| on_back.call(()),
                    "← Back to results"
                }
                span { class: "text-sm text-base-content/60",
                    "Confirm the metadata match for this title."
                }
            }

            if let Some(err) = finalize_error.read().clone() {
                div { id: "import-media-finalize-error", class: "alert alert-error",
                    "Failed to finalize import: {err}"
                }
            }

            match &*details.read_unchecked() {
                Some(Ok(d)) => {
                    let d_for_card = d.clone();
                    let d_for_confirm = d.clone();
                    rsx! {
                        MatchCard { details: d_for_card }
                        ConfirmBar {
                            label: "Confirm import".to_string(),
                            busy: *submitting.read(),
                            on_confirm: move |_| on_confirm.call(d_for_confirm.clone()),
                        }
                    }
                }
                Some(Err(err)) => {
                    let fallback = details_from_candidate(&candidate_for_fallback);
                    let fallback_for_card = fallback.clone();
                    let fallback_for_confirm = fallback.clone();
                    rsx! {
                        div { class: "alert alert-error", "Failed to load details: {err}" }
                        // Operator still sees a thin fallback summary so
                        // the page never strands them on a bare error.
                        MatchCard { details: fallback_for_card }
                        ConfirmBar {
                            label: "Confirm with partial metadata".to_string(),
                            busy: *submitting.read(),
                            on_confirm: move |_| on_confirm.call(fallback_for_confirm.clone()),
                        }
                    }
                }
                None => rsx! {
                    div { class: "py-8 text-center",
                        span { class: "loading loading-spinner loading-md" }
                    }
                },
            }
        }
    }
}

#[component]
fn ConfirmBar(label: String, busy: bool, on_confirm: Callback<MouseEvent>) -> Element {
    rsx! {
        div { class: "card bg-base-100 shadow-sm border border-base-content/5",
            div { class: "card-body py-4",
                div { class: "flex items-center justify-between gap-3",
                    p { class: "text-sm text-base-content/70",
                        "Adds the title to your library and queues a metadata refresh."
                    }
                    div { id: "import-media-confirm-wrap",
                        Button {
                            variant: ButtonVariant::Primary,
                            disabled: busy,
                            loading: busy,
                            onclick: move |evt: MouseEvent| on_confirm.call(evt),
                            "{label}"
                        }
                    }
                }
            }
        }
    }
}

#[component]
fn MatchCard(details: ImportCandidateDetails) -> Element {
    let year = details.year.map(|y| y.to_string());
    let runtime = details.runtime.map(|r| format!("{r} min"));
    let media_type_label = match details.media_type.as_str() {
        "movie" => "Movie",
        "tv_show" => "TV",
        other => other,
    };

    rsx! {
        article { id: "import-media-match-card", class: "card card-side bg-base-100 shadow-sm border border-base-content/5",
            if let Some(path) = details.poster_path.as_ref() {
                figure { class: "w-40 shrink-0",
                    img {
                        src: "https://image.tmdb.org/t/p/w300{path}",
                        alt: "{details.title}",
                        class: "object-cover w-full h-full",
                    }
                }
            } else {
                figure { class: "w-40 shrink-0 bg-base-200 flex items-center justify-center text-xs text-base-content/40",
                    "No poster"
                }
            }
            div { class: "card-body p-5 gap-2",
                div { class: "flex items-center gap-2 flex-wrap",
                    h3 { class: "card-title text-lg", "{details.title}" }
                    span { class: "badge badge-ghost", "{media_type_label}" }
                    if let Some(year) = year.as_deref() {
                        span { class: "text-sm text-base-content/70", "{year}" }
                    }
                    if let Some(runtime) = runtime.as_deref() {
                        span { class: "badge badge-outline badge-sm", "{runtime}" }
                    }
                }

                if let Some(original_title) = details.original_title.as_deref() {
                    if Some(original_title) != Some(details.title.as_str()) {
                        p { class: "text-xs text-base-content/60",
                            "Original title: "
                            em { "{original_title}" }
                        }
                    }
                }

                if let Some(tagline) = details.tagline.as_deref() {
                    p { class: "text-sm italic text-base-content/80", "{tagline}" }
                }

                if let Some(overview) = details.overview.as_deref() {
                    p { class: "text-sm text-base-content/80 line-clamp-4", "{overview}" }
                }

                if !details.genres.is_empty() {
                    div { class: "flex gap-1 flex-wrap mt-1",
                        for genre in details.genres.iter() {
                            span { class: "badge badge-sm", "{genre}" }
                        }
                    }
                }

                if details.media_type == "tv_show" {
                    if details.number_of_seasons.is_some() || details.number_of_episodes.is_some() {
                        p { class: "text-xs text-base-content/70",
                            if let Some(s) = details.number_of_seasons {
                                "{s} seasons"
                            }
                            if details.number_of_seasons.is_some() && details.number_of_episodes.is_some() {
                                " · "
                            }
                            if let Some(e) = details.number_of_episodes {
                                "{e} episodes"
                            }
                        }
                    }
                }

                if !details.production_countries.is_empty() {
                    p { class: "text-xs text-base-content/60",
                        "Country: {details.production_countries.join(\", \")}"
                    }
                }

                if let Some(lang) = details.original_language.as_deref() {
                    p { class: "text-xs text-base-content/60",
                        "Language: {lang}"
                    }
                }

                if !details.alternative_titles.is_empty() {
                    details {
                        summary { class: "text-xs text-base-content/60 cursor-pointer",
                            "Alternate titles ({details.alternative_titles.len()})"
                        }
                        ul { class: "text-xs text-base-content/70 mt-1 ml-3 list-disc",
                            for alt in details.alternative_titles.iter().take(10) {
                                li { "{alt}" }
                            }
                        }
                    }
                }
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

/// Synthesize a `details`-shaped struct from the lightweight
/// candidate when the details fetch fails. Lets the page stay useful
/// (operator can still see what they picked) instead of stranding
/// them on a bare error.
fn details_from_candidate(c: &ImportCandidate) -> ImportCandidateDetails {
    ImportCandidateDetails {
        provider: c.provider.clone(),
        external_id: c.external_id.clone(),
        title: c.title.clone(),
        original_title: c.original_title.clone(),
        year: c.year,
        overview: c.overview.clone(),
        tagline: None,
        poster_path: c.poster_path.clone(),
        backdrop_path: None,
        release_date: c.release_date.clone(),
        runtime: None,
        genres: Vec::new(),
        production_countries: Vec::new(),
        original_language: None,
        alternative_titles: Vec::new(),
        homepage: None,
        media_type: c.media_type.clone(),
        number_of_seasons: None,
        number_of_episodes: None,
    }
}
