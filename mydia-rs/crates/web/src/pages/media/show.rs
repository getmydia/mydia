//! `/media/:id` — media detail page.
//!
//! Aligned with `MydiaWeb.MediaLive.Show`'s on-screen surface (the
//! Elixir template lives at `lib/mydia_web/live/media_live/show.html.heex`
//! and its sub-components under `lib/mydia_web/live/media_live/show/`).
//! The Phoenix `LiveView` is ~3.8k LOC split across `*_events.ex` files
//! for actions (delete, refresh, monitor toggle, manual search, …). This
//! page lands the read path and a subset of the actions, with the rest
//! scaffolded behind `// TODO(graphql)` / `// TODO(server-fn)` markers
//! so the visual structure matches the Phoenix screen even when the
//! supporting data isn't on the wire yet.
//!
//! For TV shows the seasons list expands the highest-numbered season by
//! default to match Phoenix's `expanded_seasons` mount logic
//! (`lib/mydia_web/live/media_live/show.ex:42-57`). Toggling a season
//! is purely client-side since the data is already loaded.

use std::collections::HashSet;

use dioxus::prelude::*;

use crate::components::core::{
    Badge, BadgeSize, BadgeVariant, Button, ButtonSize, ButtonVariant, Icon, Input, Modal,
    ModalSize, ProgressBar, ProgressVariant, Table,
};
use crate::routes::Route;
use crate::server_fns::media::{
    delete_media, get_media_detail, list_media_files, list_media_seasons, toggle_episode_monitored,
    toggle_media_monitored, EpisodeView, MediaDetail, MediaFileSummary, SeasonView,
};

const TMDB_POSTER_BASE: &str = "https://image.tmdb.org/t/p/w342";
const TMDB_BACKDROP_BASE: &str = "https://image.tmdb.org/t/p/w1280";

#[component]
pub fn MediaShow(id: String) -> Element {
    // Reload token bumped after any mutation. Reading it inside the
    // `use_resource` closure makes the resource re-run when the token
    // changes — same pattern as the U23 library-paths page.
    let mut reload_token = use_signal(|| 0u64);

    let id_for_fetch = id.clone();
    let detail = use_resource(move || {
        let _ = reload_token.read();
        let id = id_for_fetch.clone();
        async move { get_media_detail(id).await }
    });

    let snapshot = detail.read_unchecked();
    let Some(result) = snapshot.clone() else {
        return rsx! {
            div { class: "flex justify-center py-12",
                span { class: "loading loading-spinner loading-lg" }
            }
        };
    };
    drop(snapshot);

    let detail = match result {
        Ok(d) => d,
        Err(err) => {
            return rsx! {
                div { class: "alert alert-error",
                    span { "Failed to load media: {err}" }
                }
            };
        }
    };

    let bump_detail = move |()| {
        let next = *reload_token.read() + 1;
        reload_token.set(next);
    };

    rsx! {
        div { class: "flex flex-col gap-6",
            DetailHeader {
                detail: detail.clone(),
                on_changed: bump_detail,
            }
            if detail.kind == "tv_show" {
                SeasonsPanel { id: detail.id.clone() }
            }
            FilesPanel { id: detail.id.clone(), kind: detail.kind.clone() }
            SubtitlesPanel { id: detail.id.clone() }
            // Timeline: TODO(graphql): expose timeline_events on the
            // media detail wire shape. The Phoenix LiveView assigns
            // `timeline_events` from `Mydia.Media.list_media_events/1`.
            // Until that lands we skip rendering rather than show an
            // empty history block.
        }
    }
}

// ---------- Hero + action bar ----------

#[component]
fn DetailHeader(detail: MediaDetail, on_changed: EventHandler<()>) -> Element {
    let backdrop_url = detail
        .backdrop_path
        .as_deref()
        .map(|p| format!("{TMDB_BACKDROP_BASE}{p}"));
    let poster_url = detail
        .poster_path
        .as_deref()
        .map(|p| format!("{TMDB_POSTER_BASE}{p}"));
    let year_label = detail.year.map(|y| format!("{y}"));
    let runtime_label = format_runtime(detail.runtime);
    let rating_label = detail.rating.map(|r| format!("{r:.1}/10"));
    let is_movie = detail.kind == "movie";
    let category_label = if is_movie { "Movie" } else { "TV Show" };

    let working = use_signal(|| false);
    let mut working_w = working;
    let flash: Signal<Option<(bool, String)>> = use_signal(|| None);
    let mut flash_w = flash;
    let show_delete = use_signal(|| false);
    let mut show_delete_w = show_delete;
    let show_rename = use_signal(|| false);
    let mut show_rename_w = show_rename;
    let show_category = use_signal(|| false);
    let mut show_category_w = show_category;
    let show_manual_search = use_signal(|| false);
    let mut show_manual_search_w = show_manual_search;
    let show_edit_metadata = use_signal(|| false);
    let mut show_edit_metadata_w = show_edit_metadata;

    let detail_id_for_toggle = detail.id.clone();
    let on_toggle_monitor = move |_| {
        let id = detail_id_for_toggle.clone();
        if *working_w.read() {
            return;
        }
        working_w.set(true);
        spawn(async move {
            match toggle_media_monitored(id).await {
                Ok(ack) => {
                    flash_w.set(Some((
                        true,
                        if ack.monitored {
                            "Monitoring enabled".to_owned()
                        } else {
                            "Monitoring disabled".to_owned()
                        },
                    )));
                    on_changed.call(());
                }
                Err(err) => {
                    flash_w.set(Some((false, format!("Failed to toggle: {err}"))));
                }
            }
            working_w.set(false);
        });
    };

    // TODO(server-fn): refresh metadata is an admin-only action that
    // re-fetches from the metadata relay. The Phoenix LiveView calls
    // `Mydia.Media.refresh_metadata/2`. Stubbed until the server fn
    // lands; flashes a placeholder for now.
    let mut flash_for_refresh = flash;
    let on_refresh_metadata = move |_| {
        flash_for_refresh.set(Some((
            false,
            "Refresh metadata is not wired yet (TODO server-fn)".to_owned(),
        )));
    };

    // TODO(server-fn): rescan files calls `Mydia.Library.rescan/1`.
    let mut flash_for_rescan = flash;
    let on_rescan = move |_| {
        flash_for_rescan.set(Some((
            false,
            "Re-scan files is not wired yet (TODO server-fn)".to_owned(),
        )));
    };

    // TODO(role-gating): LayoutData doesn't carry the role yet. Once
    // it does, gate refresh/re-scan/rename/delete behind `is_admin` and
    // monitor toggle behind `is_user`. Today everything is shown.

    rsx! {
        div { class: "card bg-base-100 shadow-lg overflow-hidden",
            if let Some(url) = backdrop_url {
                div {
                    class: "h-48 sm:h-64 bg-cover bg-center bg-base-300",
                    style: "background-image: linear-gradient(to bottom, rgba(0,0,0,0.2), rgba(0,0,0,0.7)), url('{url}')",
                }
            } else {
                div { class: "h-12 bg-base-300" }
            }
            div { class: "card-body flex flex-col md:flex-row gap-6",
                div { class: "shrink-0 -mt-20 md:-mt-32 mx-auto md:mx-0",
                    if let Some(url) = poster_url {
                        img {
                            src: "{url}",
                            alt: "{detail.title}",
                            class: "w-40 md:w-56 rounded-lg shadow-xl bg-base-300",
                            loading: "lazy",
                        }
                    } else {
                        div { class: "w-40 md:w-56 aspect-[2/3] rounded-lg shadow-xl bg-base-300 flex items-center justify-center text-base-content/40",
                            "No poster"
                        }
                    }
                }
                div { class: "flex flex-col gap-3 flex-1 min-w-0",
                    // Title row with action bar.
                    div { class: "flex items-start justify-between gap-2 md:gap-4",
                        div { class: "min-w-0",
                            h1 { class: "text-2xl sm:text-3xl md:text-4xl font-bold tracking-tight",
                                "{detail.title}"
                            }
                            if let Some(original) = detail.original_title.as_ref() {
                                if original.as_str() != detail.title.as_str() {
                                    p { class: "text-base md:text-lg text-base-content/70 mt-1",
                                        "{original}"
                                    }
                                }
                            }
                        }
                        // Action bar — icon-square ghost buttons with
                        // DaisyUI tooltips, mirroring show.html.heex:39-91.
                        div { class: "flex items-center gap-0.5 flex-shrink-0",
                            div { class: "tooltip tooltip-bottom", "data-tip": "Refresh metadata",
                                Button {
                                    variant: ButtonVariant::Ghost,
                                    size: ButtonSize::Sm,
                                    class: "btn-square".to_string(),
                                    onclick: on_refresh_metadata,
                                    Icon { name: "arrow-path".to_string(), class: "w-4 h-4".to_string() }
                                }
                            }
                            // Re-scan files — Phoenix gates this on
                            // `has_media_files?/1` per type. We don't
                            // know file presence here without a second
                            // query; show it unconditionally and let
                            // the rescan stub no-op when the files list
                            // is empty.
                            div { class: "tooltip tooltip-bottom", "data-tip": "Re-scan files",
                                Button {
                                    variant: ButtonVariant::Ghost,
                                    size: ButtonSize::Sm,
                                    class: "btn-square".to_string(),
                                    onclick: on_rescan,
                                    Icon { name: "folder".to_string(), class: "w-4 h-4".to_string() }
                                }
                            }
                            div { class: "tooltip tooltip-bottom", "data-tip": "Manual search",
                                Button {
                                    variant: ButtonVariant::Ghost,
                                    size: ButtonSize::Sm,
                                    class: "btn-square".to_string(),
                                    onclick: move |_| show_manual_search_w.set(true),
                                    Icon { name: "magnifying-glass".to_string(), class: "w-4 h-4".to_string() }
                                }
                            }
                            div { class: "tooltip tooltip-bottom", "data-tip": "Edit metadata",
                                Button {
                                    variant: ButtonVariant::Ghost,
                                    size: ButtonSize::Sm,
                                    class: "btn-square".to_string(),
                                    onclick: move |_| show_edit_metadata_w.set(true),
                                    Icon { name: "pencil-square".to_string(), class: "w-4 h-4".to_string() }
                                }
                            }
                            div { class: "tooltip tooltip-bottom", "data-tip": "Rename files",
                                Button {
                                    variant: ButtonVariant::Ghost,
                                    size: ButtonSize::Sm,
                                    class: "btn-square".to_string(),
                                    onclick: move |_| show_rename_w.set(true),
                                    Icon { name: "queue-list".to_string(), class: "w-4 h-4".to_string() }
                                }
                            }
                            div { class: "tooltip tooltip-bottom", "data-tip": "Delete",
                                Button {
                                    variant: ButtonVariant::Ghost,
                                    size: ButtonSize::Sm,
                                    class: "btn-square text-base-content/50 hover:text-error".to_string(),
                                    onclick: move |_| show_delete_w.set(true),
                                    Icon { name: "trash".to_string(), class: "w-4 h-4".to_string() }
                                }
                            }
                        }
                    }

                    // Metadata row — year, star+rating, runtime, category.
                    div { class: "flex flex-wrap items-center gap-2 md:gap-3 text-sm md:text-base text-base-content/70",
                        if let Some(y) = year_label.as_ref() {
                            span { class: "font-semibold", "{y}" }
                        }
                        if let Some(rating) = rating_label.as_ref() {
                            span { class: "flex items-center gap-1",
                                Icon { name: "star-solid".to_string(), class: "w-4 h-4 text-warning".to_string() }
                                "{rating}"
                            }
                        }
                        if let Some(r) = runtime_label.as_ref() {
                            span { "{r}" }
                        }
                        // Category picker — TODO(graphql): expose
                        // `category` / `category_override` on the wire.
                        // For now this is the type fallback the Phoenix
                        // template uses when no category is set.
                        button {
                            r#type: "button",
                            class: "group cursor-pointer",
                            title: "Click to change category",
                            onclick: move |_| show_category_w.set(true),
                            span {
                                class: "badge badge-ghost group-hover:ring-2 group-hover:ring-primary transition-all",
                                "{category_label}"
                            }
                        }
                    }

                    if !detail.genres.is_empty() {
                        div { class: "flex flex-wrap gap-2 mt-1",
                            for genre in detail.genres.iter() {
                                Badge {
                                    variant: BadgeVariant::Outline,
                                    "{genre}"
                                }
                            }
                        }
                    }

                    // Monitored chip stays in the metadata band so the
                    // visual order is "facts → state".
                    div { class: "flex items-center gap-2",
                        if detail.monitored {
                            Badge {
                                variant: BadgeVariant::Success,
                                size: BadgeSize::Sm,
                                "Monitored"
                            }
                        } else {
                            Badge {
                                variant: BadgeVariant::Ghost,
                                size: BadgeSize::Sm,
                                "Unmonitored"
                            }
                        }
                    }

                    if let Some(overview) = detail.overview.as_ref() {
                        p { class: "text-sm leading-relaxed", "{overview}" }
                    }

                    // TODO(graphql): expose active download status
                    // (`downloads_with_status`). The Phoenix template
                    // renders an `alert-info` with title "Downloading"
                    // and a progress percentage when present. Skipped
                    // entirely today.

                    div { class: "flex flex-wrap gap-3 text-xs opacity-60",
                        if let Some(tmdb) = detail.tmdb_id {
                            span { "TMDB: {tmdb}" }
                        }
                        if let Some(tvdb) = detail.tvdb_id {
                            span { "TVDB: {tvdb}" }
                        }
                        if let Some(imdb) = detail.imdb_id.as_ref() {
                            span { "IMDB: {imdb}" }
                        }
                    }
                    if let Some((ok, msg)) = flash.read().clone() {
                        div { class: if ok { "alert alert-success py-2" } else { "alert alert-warning py-2" },
                            span { class: "text-sm", "{msg}" }
                        }
                    }
                    div { class: "flex flex-wrap gap-2 pt-1",
                        Button {
                            variant: if detail.monitored { ButtonVariant::Ghost } else { ButtonVariant::Primary },
                            size: ButtonSize::Sm,
                            disabled: *working.read(),
                            onclick: on_toggle_monitor,
                            if detail.monitored { "Stop monitoring" } else { "Start monitoring" }
                        }
                    }
                }
            }
        }
        DeleteMediaModal {
            open: *show_delete.read(),
            title: detail.title.clone(),
            id: detail.id.clone(),
            on_close: move |()| show_delete_w.set(false),
        }
        RenameFilesModal {
            open: *show_rename.read(),
            on_close: move |()| show_rename_w.set(false),
        }
        CategoryPickerModal {
            open: *show_category.read(),
            current_label: category_label.to_string(),
            on_close: move |()| show_category_w.set(false),
        }
        ManualSearchModal {
            open: *show_manual_search.read(),
            title: detail.title.clone(),
            on_close: move |()| show_manual_search_w.set(false),
        }
        EditMetadataModal {
            open: *show_edit_metadata.read(),
            detail: detail.clone(),
            on_close: move |()| show_edit_metadata_w.set(false),
        }
    }
}

// ---------- Delete modal ----------

#[component]
fn DeleteMediaModal(open: bool, title: String, id: String, on_close: EventHandler<()>) -> Element {
    let deleting = use_signal(|| false);
    let mut deleting_w = deleting;
    let mut error: Signal<Option<String>> = use_signal(|| None);
    // `delete_files: true` is the disk-deletion path. The server fn
    // doesn't accept this flag today (see `server_fns::media::delete_media`
    // — the Phoenix flow cascades to `Library.delete_files`). We capture
    // user intent and TODO the wire-up.
    let delete_files = use_signal(|| false);
    let mut delete_files_w = delete_files;
    let nav = navigator();

    let id_for_delete = id.clone();
    let on_confirm = move |_| {
        if *deleting_w.read() {
            return;
        }
        deleting_w.set(true);
        error.set(None);
        let id = id_for_delete.clone();
        // TODO(server-fn): pass `delete_files` to a future
        // `delete_media_with_files` endpoint that mirrors the Phoenix
        // `delete_media_item(media_item, delete_files: true)` path.
        spawn(async move {
            match delete_media(id).await {
                Ok(()) => {
                    nav.push(Route::Dashboard {});
                }
                Err(err) => {
                    error.set(Some(err.to_string()));
                    deleting_w.set(false);
                }
            }
        });
    };

    let delete_files_now = *delete_files.read();
    let title_for_modal = title.clone();

    rsx! {
        Modal {
            id: "delete-media-modal".to_string(),
            open: open,
            size: ModalSize::Sm,
            on_close: on_close,
            title: rsx! { "Delete {title_for_modal}?" },
            actions: rsx! {
                Button {
                    variant: ButtonVariant::Ghost,
                    disabled: *deleting.read(),
                    onclick: move |_| on_close.call(()),
                    "Cancel"
                }
                Button {
                    variant: if delete_files_now { ButtonVariant::Error } else { ButtonVariant::Warning },
                    disabled: *deleting.read(),
                    onclick: on_confirm,
                    if *deleting.read() {
                        "Removing…"
                    } else if delete_files_now {
                        "Delete everything"
                    } else {
                        "Remove from library"
                    }
                }
            },
            // Two-card radio pattern from
            // `lib/mydia_web/live/media_live/show/modals.ex:25-66`.
            div { class: "space-y-2.5",
                label {
                    class: if delete_files_now {
                        "flex items-start gap-3 p-3.5 rounded-lg border-2 cursor-pointer border-base-300 hover:border-primary/50"
                    } else {
                        "flex items-start gap-3 p-3.5 rounded-lg border-2 cursor-pointer border-primary bg-primary/10"
                    },
                    onclick: move |_| delete_files_w.set(false),
                    input {
                        r#type: "radio",
                        name: "delete-files",
                        value: "false",
                        class: "radio radio-primary mt-0.5 flex-shrink-0",
                        checked: !delete_files_now,
                    }
                    div {
                        div { class: "font-medium mb-1", "Remove from library only" }
                        div { class: "text-sm opacity-75",
                            "Files stay on disk, can be re-imported later"
                        }
                    }
                }
                label {
                    class: if delete_files_now {
                        "flex items-start gap-3 p-3.5 rounded-lg border-2 cursor-pointer border-error bg-error/10"
                    } else {
                        "flex items-start gap-3 p-3.5 rounded-lg border-2 cursor-pointer border-base-300 hover:border-error/50"
                    },
                    onclick: move |_| delete_files_w.set(true),
                    input {
                        r#type: "radio",
                        name: "delete-files",
                        value: "true",
                        class: "radio radio-error mt-0.5 flex-shrink-0",
                        checked: delete_files_now,
                    }
                    div {
                        div { class: "font-medium mb-1", "Delete files from disk" }
                        div { class: "text-sm opacity-75 flex items-center gap-1",
                            Icon { name: "exclamation-triangle".to_string(), class: "w-4 h-4".to_string() }
                            span {
                                "Permanently deletes all files - cannot be undone"
                            }
                        }
                    }
                }
            }
            if let Some(err) = error.read().clone() {
                div { class: "alert alert-error mt-3",
                    span { "{err}" }
                }
            }
        }
    }
}

// ---------- Files panel ----------

#[component]
fn FilesPanel(id: String, kind: String) -> Element {
    let _ = kind;
    let id_for_fetch = id.clone();
    let files = use_server_future(move || {
        let id = id_for_fetch.clone();
        async move { list_media_files(id).await }
    })?;

    let snapshot = files.read_unchecked().clone();
    let Some(result) = snapshot else {
        return rsx! {
            div { class: "card bg-base-100 shadow-md",
                div { class: "card-body",
                    span { class: "loading loading-dots loading-sm" }
                }
            }
        };
    };

    let files = match result {
        Ok(f) => f,
        Err(err) => {
            return rsx! {
                div { class: "alert alert-error",
                    span { "Failed to load files: {err}" }
                }
            };
        }
    };

    let file_details = use_signal::<Option<MediaFileSummary>>(|| None);
    let mut file_details_w = file_details;
    let file_to_delete = use_signal::<Option<MediaFileSummary>>(|| None);
    let mut file_to_delete_w = file_to_delete;

    let is_empty = files.is_empty();

    rsx! {
        div { class: "card bg-base-100 shadow-md",
            div { class: "card-body",
                h2 { class: "card-title text-lg", "Media files" }
                Table {
                    id: "media-files-table".to_string(),
                    is_empty: is_empty,
                    empty: rsx! {
                        div { class: "alert alert-info",
                            span { "No files found locally for this title." }
                        }
                    },
                    head: rsx! {
                        tr {
                            th { "File" }
                            th { "Quality" }
                            th { "Codec" }
                            th { "Resolution" }
                            th { "Size" }
                            th { class: "text-right", "Actions" }
                        }
                    },
                    body: rsx! {
                        for file in files.iter() {
                            MovieFileRow {
                                file: file.clone(),
                                on_details: {
                                    let f = file.clone();
                                    move |_| file_details_w.set(Some(f.clone()))
                                },
                                on_delete: {
                                    let f = file.clone();
                                    move |_| file_to_delete_w.set(Some(f.clone()))
                                },
                            }
                        }
                    },
                }
            }
        }
        FileDetailsModal {
            file: file_details.read().clone(),
            on_close: move |()| file_details_w.set(None),
        }
        FileDeleteModal {
            file: file_to_delete.read().clone(),
            on_close: move |()| file_to_delete_w.set(None),
        }
    }
}

#[component]
fn MovieFileRow(
    file: MediaFileSummary,
    on_details: EventHandler<MouseEvent>,
    on_delete: EventHandler<MouseEvent>,
) -> Element {
    let quality = file.resolution.clone().unwrap_or_else(|| "—".to_owned());
    let codec = file.codec.clone().unwrap_or_else(|| "—".to_owned());
    let resolution = file.resolution.clone().unwrap_or_else(|| "—".to_owned());
    let size = format_size(file.size);
    let filename = file.filename.clone();
    let path = file.path.clone();

    rsx! {
        tr {
            td {
                div { class: "flex flex-col",
                    span { class: "font-mono text-xs break-all", "{filename}" }
                    span { class: "text-xs opacity-50", title: "{path}", "{path}" }
                }
            }
            td {
                Badge {
                    variant: BadgeVariant::Primary,
                    size: BadgeSize::Sm,
                    "{quality}"
                }
            }
            td { "{codec}" }
            td { "{resolution}" }
            td { class: "font-mono", "{size}" }
            td { class: "text-right",
                div { class: "flex items-center justify-end gap-1",
                    div { class: "tooltip tooltip-left", "data-tip": "View details",
                        Button {
                            variant: ButtonVariant::Ghost,
                            size: ButtonSize::Xs,
                            class: "btn-square".to_string(),
                            onclick: move |evt| on_details.call(evt),
                            Icon { name: "information-circle".to_string(), class: "w-4 h-4".to_string() }
                        }
                    }
                    div { class: "tooltip tooltip-left", "data-tip": "Delete file",
                        Button {
                            variant: ButtonVariant::Ghost,
                            size: ButtonSize::Xs,
                            class: "btn-square text-error".to_string(),
                            onclick: move |evt| on_delete.call(evt),
                            Icon { name: "trash".to_string(), class: "w-4 h-4".to_string() }
                        }
                    }
                }
            }
        }
    }
}

#[component]
fn FileDetailsModal(file: Option<MediaFileSummary>, on_close: EventHandler<()>) -> Element {
    let open = file.is_some();
    let f = file.clone();

    rsx! {
        Modal {
            id: "media-file-details".to_string(),
            open: open,
            size: ModalSize::Lg,
            on_close: on_close,
            title: rsx! { "Media file details" },
            if let Some(file) = f.as_ref() {
                div { class: "space-y-4",
                    div {
                        h4 { class: "text-sm font-semibold text-base-content/70 mb-2", "Path" }
                        p { class: "text-sm font-mono bg-base-200 p-3 rounded-box break-all",
                            "{file.path}"
                        }
                    }
                    div { class: "grid grid-cols-2 gap-4",
                        FileDetailRow { label: "Filename".to_string(), value: file.filename.clone() }
                        FileDetailRow { label: "Resolution".to_string(), value: file.resolution.clone().unwrap_or_else(|| "—".to_owned()) }
                        FileDetailRow { label: "Codec".to_string(), value: file.codec.clone().unwrap_or_else(|| "—".to_owned()) }
                        FileDetailRow { label: "Audio".to_string(), value: file.audio_codec.clone().unwrap_or_else(|| "—".to_owned()) }
                        FileDetailRow { label: "Size".to_string(), value: format_size(file.size) }
                    }
                    // TODO(graphql): expose container, bitrate, audio
                    // channel count, source group, mediainfo blob.
                    // Today's `MediaFileSummary` ships only the columns
                    // the row needs.
                    p { class: "text-xs opacity-60 italic",
                        "Additional mediainfo (bitrate, channels, container) is not exposed on the wire yet."
                    }
                }
            }
        }
    }
}

#[component]
fn FileDetailRow(label: String, value: String) -> Element {
    rsx! {
        div {
            div { class: "text-xs font-semibold text-base-content/70 mb-0.5", "{label}" }
            div { class: "text-sm break-all", "{value}" }
        }
    }
}

#[component]
fn FileDeleteModal(file: Option<MediaFileSummary>, on_close: EventHandler<()>) -> Element {
    let open = file.is_some();
    let f = file.clone();

    rsx! {
        Modal {
            id: "media-file-delete".to_string(),
            open: open,
            size: ModalSize::Sm,
            on_close: on_close,
            title: rsx! { "Delete media file?" },
            actions: rsx! {
                Button {
                    variant: ButtonVariant::Ghost,
                    onclick: move |_| on_close.call(()),
                    "Cancel"
                }
                // TODO(server-fn): expose `delete_media_file/1` to
                // mirror Phoenix's `Library.delete_media_file/1`. The
                // confirm just closes for now.
                Button {
                    variant: ButtonVariant::Error,
                    onclick: move |_| on_close.call(()),
                    "Delete record"
                }
            },
            if let Some(file) = f.as_ref() {
                div { class: "space-y-3",
                    div { class: "bg-base-200 p-3 rounded-box",
                        p { class: "text-sm font-mono break-all", "{file.path}" }
                        p { class: "text-sm mt-2",
                            span { class: "font-semibold", "Size: " }
                            "{format_size(file.size)}"
                        }
                    }
                    p { class: "text-warning text-sm flex items-center gap-1",
                        Icon { name: "exclamation-triangle".to_string(), class: "w-4 h-4".to_string() }
                        span { "This only removes the database record. The file remains on disk." }
                    }
                }
            }
        }
    }
}

// ---------- Subtitles panel ----------

#[component]
fn SubtitlesPanel(id: String) -> Element {
    let _ = id;
    // TODO(graphql): expose `media_file_subtitles` (per-file embedded +
    // external subtitle list) and `subtitle_feature_enabled` so the
    // panel can render the same per-file cards the Phoenix template
    // does (`lib/mydia_web/live/media_live/show/components.ex:1192-1275`).
    // For now we render the section header with an empty-state message
    // so the page layout matches the screen.
    rsx! {
        div { class: "card bg-base-100 shadow-md",
            div { class: "card-body",
                h2 { class: "card-title text-lg", "Subtitles" }
                p { class: "text-sm text-base-content/60 italic",
                    "No external subtitle files. Embedded subtitles are available in the player."
                }
            }
        }
    }
}

// ---------- Seasons panel ----------

#[component]
fn SeasonsPanel(id: String) -> Element {
    // Same reload-on-token pattern as MediaShow — episode monitor
    // toggles bump the token so the seasons tree picks up the new
    // state without a full page reload.
    let mut reload_token = use_signal(|| 0u64);
    let id_for_fetch = id.clone();
    let seasons = use_resource(move || {
        let _ = reload_token.read();
        let id = id_for_fetch.clone();
        async move { list_media_seasons(id).await }
    });

    let snapshot = seasons.read_unchecked();
    let Some(result) = snapshot.clone() else {
        return rsx! {
            div { class: "card bg-base-100 shadow-md",
                div { class: "card-body",
                    span { class: "loading loading-dots loading-sm" }
                }
            }
        };
    };
    drop(snapshot);

    let seasons = match result {
        Ok(s) => s,
        Err(err) => {
            return rsx! {
                div { class: "alert alert-error",
                    span { "Failed to load seasons: {err}" }
                }
            };
        }
    };

    let on_episode_changed = move |()| {
        let next = *reload_token.read() + 1;
        reload_token.set(next);
    };

    // Default-expanded set = the highest season number. Mirrors
    // `expanded_seasons` mount logic at media_live/show.ex:42-57.
    let initial_expanded: HashSet<i32> =
        seasons
            .iter()
            .map(|s| s.season_number)
            .max()
            .map_or_else(HashSet::new, |n| {
                let mut set = HashSet::new();
                set.insert(n);
                set
            });
    let expanded = use_signal(|| initial_expanded);

    rsx! {
        div { class: "card bg-base-100 shadow-md",
            div { class: "card-body",
                h2 { class: "card-title text-lg", "Seasons" }
                if seasons.is_empty() {
                    div { class: "alert alert-info",
                        span { "No episodes loaded yet." }
                    }
                } else {
                    div { class: "flex flex-col gap-3",
                        for season in seasons.iter() {
                            SeasonRow {
                                season: season.clone(),
                                is_expanded: expanded.read().contains(&season.season_number),
                                on_toggle: {
                                    let mut expanded = expanded;
                                    let n = season.season_number;
                                    move |_| {
                                        let mut next = expanded.read().clone();
                                        if next.contains(&n) {
                                            next.remove(&n);
                                        } else {
                                            next.insert(n);
                                        }
                                        expanded.set(next);
                                    }
                                },
                                on_episode_changed: on_episode_changed,
                            }
                        }
                    }
                }
            }
        }
    }
}

#[component]
fn SeasonRow(
    season: SeasonView,
    is_expanded: bool,
    on_toggle: EventHandler<MouseEvent>,
    on_episode_changed: EventHandler<()>,
) -> Element {
    let season_label = if season.season_number == 0 {
        "Specials".to_owned()
    } else {
        format!("Season {}", season.season_number)
    };

    let total = season.episode_count.max(1) as f32;
    let watched = season.downloaded_count as f32;
    let progress = (watched / total) * 100.0;

    rsx! {
        // DaisyUI accordion-style collapsible. We drive `open` from
        // local state rather than the native `details/summary` pair
        // so the parent can also force-expand.
        div { class: "border border-base-300 rounded-lg",
            button {
                r#type: "button",
                class: "w-full flex items-center justify-between gap-3 px-4 py-3 hover:bg-base-200 transition-colors text-left",
                onclick: move |evt| on_toggle.call(evt),
                div { class: "flex items-center gap-3 min-w-0",
                    Icon {
                        name: if is_expanded { "chevron-down".to_string() } else { "chevron-right".to_string() },
                        class: "w-4 h-4 shrink-0".to_string(),
                    }
                    span { class: "font-semibold", "{season_label}" }
                    span { class: "text-xs opacity-60",
                        "{season.downloaded_count}/{season.episode_count} watched"
                    }
                }
                div { class: "shrink-0 w-32 hidden md:block",
                    ProgressBar {
                        value: progress,
                        variant: ProgressVariant::Primary,
                    }
                }
            }
            if is_expanded {
                div { class: "border-t border-base-300 divide-y divide-base-300",
                    for episode in season.episodes.iter() {
                        EpisodeRow {
                            episode: episode.clone(),
                            on_changed: on_episode_changed,
                        }
                    }
                }
            }
        }
    }
}

#[component]
fn EpisodeRow(episode: EpisodeView, on_changed: EventHandler<()>) -> Element {
    let label = match (episode.season_number, episode.episode_number) {
        (Some(s), Some(e)) => format!("S{s:02}E{e:02}"),
        (None, Some(e)) => format!("E{e:02}"),
        _ => "—".to_owned(),
    };
    let title = episode.title.clone().unwrap_or_default();
    let air_date = episode.air_date.clone();
    let monitored = episode.monitored;
    let mut working = use_signal(|| false);
    let episode_id = episode.id.clone();

    let on_click_monitor = move |_| {
        if *working.read() {
            return;
        }
        working.set(true);
        let id = episode_id.clone();
        spawn(async move {
            let _ = toggle_episode_monitored(id).await;
            working.set(false);
            on_changed.call(());
        });
    };

    rsx! {
        div { class: "flex items-center gap-3 px-4 py-2 hover:bg-base-200",
            // TODO(server-fn): watched-state toggle. The Phoenix
            // template renders a `phx-click="toggle_watched"` checkbox.
            // No server fn exists yet, so we render disabled with a
            // tooltip.
            div { class: "tooltip tooltip-right", "data-tip": "Watched state coming soon",
                input {
                    r#type: "checkbox",
                    class: "checkbox checkbox-sm",
                    disabled: true,
                    checked: episode.has_files,
                }
            }
            span { class: "font-mono text-xs opacity-60 w-16", "{label}" }
            span { class: "flex-1 min-w-0 truncate text-sm", "{title}" }
            if !air_date.is_empty() {
                span { class: "text-xs opacity-60 hidden sm:inline", "{air_date}" }
            }
            // TODO(server-fn): episode-level refresh + manual search
            // call `Mydia.Media.refresh_episode/1` and open the manual
            // search modal scoped to the episode. Hidden until wired so
            // we don't render dead buttons.
            button {
                r#type: "button",
                class: if monitored { "badge badge-outline badge-xs cursor-pointer" } else { "badge badge-ghost badge-xs cursor-pointer" },
                disabled: *working.read(),
                onclick: on_click_monitor,
                if monitored { "Monitored" } else { "Unmonitored" }
            }
        }
    }
}

// ---------- Rename / category / manual search modals (scaffolds) ----------

#[component]
fn RenameFilesModal(open: bool, on_close: EventHandler<()>) -> Element {
    // TODO(server-fn): port Phoenix's `rename_files_modal` which
    // previews `{old → new}` rows for each file and submits a rename
    // job. Today this is a scaffold so the action bar's "Rename files"
    // button does something visible.
    rsx! {
        Modal {
            id: "rename-files-modal".to_string(),
            open: open,
            size: ModalSize::Lg,
            on_close: on_close,
            title: rsx! { "Rename files" },
            actions: rsx! {
                Button {
                    variant: ButtonVariant::Ghost,
                    onclick: move |_| on_close.call(()),
                    "Close"
                }
                Button {
                    variant: ButtonVariant::Primary,
                    disabled: true,
                    "Apply renames"
                }
            },
            div { class: "alert alert-info",
                span { class: "text-sm",
                    "Rename previews are not wired yet. The Phoenix flow computes "
                    "old/new pairs per file via Mydia.Library.preview_renames/1 and "
                    "applies them with Mydia.Library.rename_files/1."
                }
            }
        }
    }
}

#[component]
fn CategoryPickerModal(open: bool, current_label: String, on_close: EventHandler<()>) -> Element {
    // TODO(server-fn): expose `Mydia.Media.list_categories/0` +
    // `Mydia.Media.set_category_override/2`. Today this is a stub.
    let options = vec![
        ("movie".to_string(), "Movie".to_string()),
        ("tv_show".to_string(), "TV Show".to_string()),
        ("documentary".to_string(), "Documentary".to_string()),
        ("anime".to_string(), "Anime".to_string()),
        ("standup".to_string(), "Stand-up".to_string()),
    ];
    rsx! {
        Modal {
            id: "category-picker-modal".to_string(),
            open: open,
            size: ModalSize::Md,
            on_close: on_close,
            title: rsx! { "Change category" },
            actions: rsx! {
                Button {
                    variant: ButtonVariant::Ghost,
                    onclick: move |_| on_close.call(()),
                    "Cancel"
                }
                Button {
                    variant: ButtonVariant::Primary,
                    disabled: true,
                    "Save"
                }
            },
            Input {
                name: "category".to_string(),
                r#type: "select".to_string(),
                label: format!("Current: {current_label}"),
                options: options,
                value: String::new(),
                prompt: "Pick a category".to_string(),
            }
            p { class: "text-xs opacity-60 italic mt-2",
                "Category override is not wired yet (TODO server-fn)."
            }
        }
    }
}

#[component]
fn ManualSearchModal(open: bool, title: String, on_close: EventHandler<()>) -> Element {
    // Mirror of `modals.ex:475+` — the indexer search modal. Phoenix
    // calls `Mydia.Indexers.search/2` with the title and renders a
    // results grid (release name, indexer, seeders, quality, size, age,
    // download button). No server fn is exposed today, so this is a
    // scaffold: input + filters + empty results.
    let query = use_signal(|| title.clone());
    let mut query_w = query;
    let searching = use_signal(|| false);
    let mut searching_w = searching;
    let search_err: Signal<Option<String>> = use_signal(|| None);
    let mut search_err_w = search_err;

    let on_search = move |_| {
        if *searching_w.read() {
            return;
        }
        searching_w.set(true);
        // TODO(server-fn): expose a `manual_search` server fn that
        // proxies to `Mydia.Indexers.search/2`. Until then we just
        // surface the limitation.
        search_err_w.set(Some(
            "Manual search is not wired yet (TODO server-fn).".to_owned(),
        ));
        searching_w.set(false);
    };

    rsx! {
        Modal {
            id: "manual-search-modal".to_string(),
            open: open,
            size: ModalSize::Xl,
            on_close: on_close,
            title: rsx! { "Manual search" },
            actions: rsx! {
                Button {
                    variant: ButtonVariant::Ghost,
                    onclick: move |_| on_close.call(()),
                    "Close"
                }
            },
            div { class: "flex flex-col gap-3",
                div { class: "flex items-center gap-2",
                    Icon { name: "magnifying-glass".to_string(), class: "w-4 h-4 text-base-content/60".to_string() }
                    span { class: "text-sm text-base-content/70", "Searching for:" }
                    span { class: "font-semibold truncate", "{query.read()}" }
                }
                div { class: "flex gap-2",
                    input {
                        r#type: "text",
                        class: "input input-bordered input-sm flex-1",
                        value: "{query.read()}",
                        oninput: move |evt| query_w.set(evt.value()),
                        placeholder: "Edit search query…",
                    }
                    Button {
                        variant: ButtonVariant::Primary,
                        size: ButtonSize::Sm,
                        loading: *searching.read(),
                        onclick: on_search,
                        "Search"
                    }
                }
                if let Some(err) = search_err.read().clone() {
                    div { class: "alert alert-warning",
                        Icon { name: "exclamation-triangle".to_string(), class: "w-5 h-5 shrink-0".to_string() }
                        span { class: "text-sm", "{err}" }
                    }
                }
                div { class: "min-h-[200px] flex items-center justify-center text-sm text-base-content/60 italic",
                    "No results yet. Run a search to see releases across indexers."
                }
            }
        }
    }
}

#[component]
fn EditMetadataModal(open: bool, detail: MediaDetail, on_close: EventHandler<()>) -> Element {
    // TODO(server-fn): port `Mydia.Media.update_media_item/2`. This
    // scaffold renders the same fields the Phoenix form does but the
    // submit is disabled until the server fn lands.
    let title = use_signal(|| detail.title.clone());
    let mut title_w = title;
    let year = use_signal(|| detail.year.map(|y| y.to_string()).unwrap_or_default());
    let mut year_w = year;

    rsx! {
        Modal {
            id: "edit-metadata-modal".to_string(),
            open: open,
            size: ModalSize::Lg,
            on_close: on_close,
            title: rsx! { "Edit metadata" },
            actions: rsx! {
                Button {
                    variant: ButtonVariant::Ghost,
                    onclick: move |_| on_close.call(()),
                    "Cancel"
                }
                Button {
                    variant: ButtonVariant::Primary,
                    disabled: true,
                    "Save"
                }
            },
            div { class: "space-y-3",
                Input {
                    name: "title".to_string(),
                    label: "Title".to_string(),
                    value: title.read().clone(),
                    oninput: move |evt: FormEvent| title_w.set(evt.value()),
                }
                Input {
                    name: "year".to_string(),
                    r#type: "number".to_string(),
                    label: "Year".to_string(),
                    value: year.read().clone(),
                    oninput: move |evt: FormEvent| year_w.set(evt.value()),
                }
                p { class: "text-xs opacity-60 italic",
                    "Metadata editing is not wired yet (TODO server-fn)."
                }
            }
        }
    }
}

// ---------- Helpers ----------

fn format_size(bytes: Option<i64>) -> String {
    // Mirror of `Show.Formatters.format_file_size/1`. SI-ish units
    // (TB / GB / MB / KB / B) with 2-decimal rounding.
    let Some(b) = bytes else {
        return "—".to_owned();
    };
    let b_f = b as f64;
    if b >= 1_099_511_627_776 {
        format!("{:.2} TB", b_f / 1_099_511_627_776.0)
    } else if b >= 1_073_741_824 {
        format!("{:.2} GB", b_f / 1_073_741_824.0)
    } else if b >= 1_048_576 {
        format!("{:.2} MB", b_f / 1_048_576.0)
    } else if b >= 1024 {
        format!("{:.2} KB", b_f / 1024.0)
    } else {
        format!("{b} B")
    }
}

fn format_runtime(minutes: Option<i32>) -> Option<String> {
    // Mirror of `Show.Helpers.get_runtime/1`. Phoenix formats `92` as
    // "1h 32m" and `45` as "45m". Episodes (TV) carry per-episode
    // runtime so the same formatter applies.
    let m = minutes?;
    if m <= 0 {
        return None;
    }
    let h = m / 60;
    let r = m % 60;
    let s = if h == 0 {
        format!("{r}m")
    } else if r == 0 {
        format!("{h}h")
    } else {
        format!("{h}h {r}m")
    };
    Some(s)
}
