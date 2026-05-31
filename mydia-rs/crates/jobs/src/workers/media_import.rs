//! Port of `lib/mydia/jobs/media_import.ex` (~1845 LOC in Phoenix).
//!
//! Imports a completed download into the library: hardlinks (preferred,
//! when on same filesystem), moves, or copies the files into their
//! organized target paths, creates the `media_files` rows, and
//! optionally removes the source from the download client.
//!
//! ## Operation priority
//!
//! 1. Hardlink (instant, no duplicate storage) — requires same fs.
//! 2. Move — when `use_hardlinks=false` and `move_files=true`.
//! 3. Copy — default, safest.

use std::path::{Path, PathBuf};
use std::str::FromStr;

use apalis::prelude::Data;
use chrono::Utc;
use sea_orm::sea_query::{Expr, ExprTrait};
use sea_orm::{ColumnTrait, DatabaseConnection, EntityTrait, QueryFilter, Set};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use mydia_rs_db::types::{DateTimeSecs, UuidText};
use mydia_rs_entities::{downloads, episodes, library_paths, media_files, media_items};
use mydia_rs_library::{
    FileOrganizer, OrganizeInput, OrganizeMetadata, ParsedFileInfo, ReleaseParser,
};
use mydia_rs_pubsub::Event;

use crate::context::AppContext;
use crate::queues::Queue;
use crate::storage::JobsError;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MediaImportArgs {
    pub download_id: String,
    #[serde(default)]
    pub target_files: Option<serde_json::Value>,
    #[serde(default)]
    pub save_path: Option<String>,
    #[serde(default)]
    pub snooze_count: u32,
    #[serde(default = "default_true")]
    pub use_hardlinks: bool,
    #[serde(default)]
    pub move_files: bool,
    #[serde(default)]
    pub rename_files: bool,
}

const fn default_true() -> bool {
    true
}

pub const QUEUE: Queue = Queue::Default;
pub const MAX_ATTEMPTS: u32 = 1000;

/// Maximum snooze retries for incomplete downloads (5 min each, ~1h).
const MAX_SNOOZE_COUNT: u32 = 12;

pub async fn media_import(args: MediaImportArgs, ctx: Data<AppContext>) -> Result<(), JobsError> {
    tracing::info!(
        download_id = %args.download_id,
        snooze_count = args.snooze_count,
        use_hardlinks = args.use_hardlinks,
        "starting media import"
    );

    let Some(download) = fetch_download(&ctx.db, &args.download_id).await? else {
        tracing::warn!(download_id = %args.download_id, "download not found; skipping");
        return Ok(());
    };

    // Idempotency: already imported.
    if download.imported_at.is_some() {
        tracing::debug!(download_id = %args.download_id, "already imported; skipping");
        return Ok(());
    }

    // Incomplete: snooze and retry.
    if download.completed_at.is_none() {
        if args.snooze_count < MAX_SNOOZE_COUNT {
            tracing::debug!(
                download_id = %args.download_id,
                snooze = args.snooze_count,
                "download not yet complete; snoozing"
            );
            return Err(JobsError::Retryable("download not yet complete".into()));
        }
        stamp_import_failed(
            &ctx.db,
            &download.id,
            "download never completed after max snooze retries",
        )
        .await;
        return Ok(());
    }

    match import_download(&download, &args, &ctx).await {
        Ok(summary) => {
            tracing::info!(
                download_id = %args.download_id,
                imported = summary.imported,
                unresolved = summary.unresolved,
                errors = summary.errors,
                "media import completed"
            );
            ctx.pubsub.publish(
                mydia_rs_pubsub::topics::JOBS_STATUS,
                Event::from_json(serde_json::json!({
                    "event": "import_completed",
                    "download_id": args.download_id,
                    "imported": summary.imported,
                    "unresolved": summary.unresolved,
                    "errors": summary.errors,
                })),
            );
            Ok(())
        }
        Err(e) => {
            tracing::error!(download_id = %args.download_id, error = %e, "media import failed");
            Err(e)
        }
    }
}

#[derive(Debug, Default)]
struct ImportSummary {
    imported: usize,
    unresolved: usize,
    errors: usize,
}

async fn fetch_download(
    db: &DatabaseConnection,
    id: &str,
) -> Result<Option<downloads::Model>, JobsError> {
    let Ok(uuid) = Uuid::from_str(id) else {
        return Ok(None);
    };
    let backend = db.get_database_backend();
    downloads::Entity::find()
        .filter(Expr::col(downloads::Column::Id).eq(UuidText(uuid).into_simple_expr(backend)))
        .one(db)
        .await
        .map_err(JobsError::Db)
}

async fn import_download(
    download: &downloads::Model,
    args: &MediaImportArgs,
    ctx: &AppContext,
) -> Result<ImportSummary, JobsError> {
    let mut summary = ImportSummary::default();

    // Resolve library path.
    let library_path = resolve_library_path(ctx, download).await?;
    tracing::debug!(
        library_path_id = %library_path.id,
        path = %library_path.path,
        "resolved library path"
    );

    // Get file list: targeted or full.
    let file_paths = if let Some(ref target_files) = args.target_files {
        resolve_target_files(target_files)
    } else {
        list_download_files(ctx, download, args.save_path.as_deref()).await?
    };

    if file_paths.is_empty() {
        stamp_import_failed(&ctx.db, &download.id, "no importable files").await;
        return Ok(summary);
    }

    for source_path in &file_paths {
        match import_single_file(source_path, download, &library_path, args, ctx).await {
            Ok(()) => summary.imported += 1,
            Err(FileImportOutcome::Unresolved) => summary.unresolved += 1,
            Err(FileImportOutcome::Failed(reason)) => {
                tracing::warn!(reason, source = %source_path.display(), "file import failed");
                summary.errors += 1;
            }
        }
    }

    // Stamp imported_at if anything was imported.
    if summary.imported > 0 {
        stamp_imported_at(&ctx.db, &download.id).await;
    }

    Ok(summary)
}

enum FileImportOutcome {
    Unresolved,
    Failed(String),
}

async fn import_single_file(
    source_path: &Path,
    download: &downloads::Model,
    library_path: &library_paths::Model,
    args: &MediaImportArgs,
    ctx: &AppContext,
) -> Result<(), FileImportOutcome> {
    let filename = source_path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("unknown");
    let parsed = ReleaseParser::parse(filename);

    // Match to media item / episode.
    let (media_item_id, episode_id, match_title, match_year) =
        resolve_destination_ids(download, &parsed, ctx).await?;

    // Compute destination.
    let metadata = OrganizeMetadata {
        title: match_title,
        original_title: None,
        year: match_year,
        episode_title: None,
    };
    let input = OrganizeInput {
        library_path: PathBuf::from(&library_path.path),
        parsed: parsed.clone(),
        metadata: Some(metadata),
        category: None,
        rename: args.rename_files,
        file_template: None,
        folder_template: None,
    };

    let organizer = FileOrganizer;
    let dest = organizer.destination_path(&input);

    // Ensure parent directory.
    if let Some(parent) = dest.parent() {
        tokio::fs::create_dir_all(parent)
            .await
            .map_err(|e| FileImportOutcome::Failed(format!("mkdir failed: {e}")))?;
    }

    // Execute file operation: hardlink > move > copy.
    let file_size = copy_or_link(source_path, &dest, args.use_hardlinks, args.move_files)
        .await
        .map_err(FileImportOutcome::Failed)?;

    // Create media_files row.
    let mf_id = UuidText(Uuid::new_v4());
    let now = DateTimeSecs::from(Utc::now());
    let relative_path = compute_relative_path(&library_path.path, &dest);

    let am = media_files::ActiveModel {
        id: Set(mf_id),
        media_item_id: Set(Some(media_item_id)),
        episode_id: Set(episode_id),
        library_path_id: Set(Some(library_path.id)),
        path: Set(Some(dest.to_string_lossy().into_owned())),
        relative_path: Set(Some(relative_path)),
        size: Set(Some(file_size)),
        quality_profile_id: Set(library_path.quality_profile_id),
        resolution: Set(parsed.quality.resolution),
        codec: Set(parsed.quality.codec),
        audio_codec: Set(parsed.quality.audio),
        hdr_format: Set(parsed.quality.hdr_format),
        inserted_at: Set(now),
        updated_at: Set(now),
        ..Default::default()
    };

    mydia_rs_db::insert_active_model(am, &ctx.db)
        .await
        .map_err(|e| FileImportOutcome::Failed(format!("media_files insert failed: {e}")))?;

    Ok(())
}

/// Resolve `media_item_id` and optional `episode_id` for a parsed file.
async fn resolve_destination_ids(
    download: &downloads::Model,
    parsed: &ParsedFileInfo,
    ctx: &AppContext,
) -> Result<(UuidText, Option<UuidText>, Option<String>, Option<i32>), FileImportOutcome> {
    // If download already has media_item_id (targeted), use it.
    if let Some(mi_id) = download.media_item_id {
        // For TV shows, resolve episode if season + episode parsed.
        if let (Some(season), Some(eps)) = (parsed.season, &parsed.episodes) {
            if let Some(ep_num) = eps.first().copied() {
                if let Ok(Some(ep)) = find_episode(&ctx.db, &mi_id, season, ep_num).await {
                    let title = download.title.clone();
                    return Ok((mi_id, Some(ep.id), Some(title), None));
                }
            }
        }
        // Movie or unmatched episode: use download match.
        let title = download.title.clone();
        return Ok((mi_id, download.episode_id, Some(title), None));
    }

    // TV show: try episode lookup from parsed data.
    if parsed.kind == mydia_rs_library::MediaKind::TvShow {
        if let (Some(season), Some(eps)) = (parsed.season, &parsed.episodes) {
            if let Some(ep_num) = eps.first().copied() {
                // Search for the show first by parsed title.
                let title = parsed.title.clone().unwrap_or_default();
                if let Some(mi_id) = find_media_item_by_title(&ctx.db, &title).await {
                    if let Ok(Some(ep)) = find_episode(&ctx.db, &mi_id, season, ep_num).await {
                        return Ok((mi_id, Some(ep.id), Some(title), None));
                    }
                }
            }
        }
    }

    // Fallback: return unresolved.
    Err(FileImportOutcome::Unresolved)
}

async fn find_episode(
    db: &DatabaseConnection,
    media_item_id: &UuidText,
    season: i32,
    episode_number: i32,
) -> Result<Option<episodes::Model>, JobsError> {
    let backend = db.get_database_backend();
    episodes::Entity::find()
        .filter(
            Expr::col(episodes::Column::MediaItemId).eq((*media_item_id).into_simple_expr(backend)),
        )
        .filter(episodes::Column::SeasonNumber.eq(season))
        .filter(episodes::Column::EpisodeNumber.eq(episode_number))
        .one(db)
        .await
        .map_err(JobsError::Db)
}

async fn find_media_item_by_title(db: &DatabaseConnection, title: &str) -> Option<UuidText> {
    let normalized = mydia_rs_library::normalize_search_query(title);
    use sea_orm::sea_query::Func;
    media_items::Entity::find()
        .filter(sea_orm::sea_query::Expr::expr(
            Func::lower(Expr::col(media_items::Column::Title)).equals(normalized.to_lowercase()),
        ))
        .one(db)
        .await
        .ok()
        .flatten()
        .map(|r| r.id)
}

/// Priority: hardlink (same-fs) → move → copy.
async fn copy_or_link(
    source: &Path,
    dest: &Path,
    prefer_hardlink: bool,
    prefer_move: bool,
) -> Result<i64, String> {
    let size = tokio::fs::metadata(source)
        .await
        .map(|m| m.len() as i64)
        .unwrap_or(0);

    // Attempt hardlink.
    if prefer_hardlink {
        match std::fs::hard_link(source, dest) {
            Ok(()) => {
                let src_meta = std::fs::metadata(source).map_err(|e| e.to_string())?;
                let dst_meta = std::fs::metadata(dest).map_err(|e| e.to_string())?;
                #[cfg(unix)]
                {
                    use std::os::unix::fs::MetadataExt;
                    if src_meta.dev() == dst_meta.dev() && src_meta.ino() == dst_meta.ino() {
                        return Ok(size);
                    }
                }
                #[cfg(not(unix))]
                {
                    if src_meta.len() == dst_meta.len() {
                        return Ok(size);
                    }
                }
                // Cross-device: remove the copy and fall through.
                let _ = std::fs::remove_file(dest);
            }
            Err(e) => {
                tracing::debug!(source = %source.display(), dest = %dest.display(), error = %e, "hardlink failed; falling back");
            }
        }
    }

    // Attempt move.
    if prefer_move {
        match std::fs::rename(source, dest) {
            Ok(()) => return Ok(size),
            Err(e) if e.kind() == std::io::ErrorKind::CrossesDevices => {
                tracing::debug!("move cross-device; falling back to copy");
            }
            Err(e) => return Err(format!("move failed: {e}")),
        }
    }

    // Fallback: copy.
    tokio::fs::copy(source, dest)
        .await
        .map(|n| n as i64)
        .map_err(|e| format!("copy failed: {e}"))
}

fn compute_relative_path(library_root: &str, full_path: &Path) -> String {
    let root = PathBuf::from(library_root);
    full_path
        .strip_prefix(&root)
        .ok()
        .and_then(|p| p.to_str())
        .map_or_else(|| full_path.to_string_lossy().into_owned(), str::to_owned)
}

async fn resolve_library_path(
    ctx: &AppContext,
    download: &downloads::Model,
) -> Result<library_paths::Model, JobsError> {
    // If download has a specific library_path_id, use it.
    if let Some(lp_id) = download.library_path_id {
        let backend = ctx.db.get_database_backend();
        if let Some(lp) = library_paths::Entity::find()
            .filter(Expr::col(library_paths::Column::Id).eq(lp_id.into_simple_expr(backend)))
            .one(&ctx.db)
            .await?
        {
            return Ok(lp);
        }
    }

    // Fallback: first monitored library path.
    library_paths::Entity::find()
        .filter(library_paths::Column::Monitored.eq(true))
        .one(&ctx.db)
        .await?
        .ok_or_else(|| JobsError::NotFound("no monitored library path configured".into()))
}

async fn list_download_files(
    ctx: &AppContext,
    download: &downloads::Model,
    save_path: Option<&str>,
) -> Result<Vec<PathBuf>, JobsError> {
    // Try download client first.
    if let Some(ref client_name) = download.download_client {
        if let Some(ref client_id) = download.download_client_id {
            if let Some(client) = ctx.downloads.get(client_name) {
                if let Ok(files) = client.get_files(&default_client_config(), client_id).await {
                    return Ok(files.into_iter().map(PathBuf::from).collect());
                }
            }
        }
    }

    // Fallback to save_path (from args or download metadata).
    let sp: Option<String> = save_path.map(str::to_owned).or_else(|| {
        download
            .metadata
            .as_deref()
            .and_then(|m| serde_json::from_str::<serde_json::Value>(m).ok())
            .and_then(|v| {
                v.get("save_path")
                    .and_then(|s| s.as_str())
                    .map(str::to_owned)
            })
    });

    if let Some(path) = sp {
        let metadata = tokio::fs::metadata(&path)
            .await
            .map_err(|e| JobsError::WorkerError(format!("save_path inaccessible: {e}")))?;
        if metadata.is_dir() {
            let mut entries = tokio::fs::read_dir(&path)
                .await
                .map_err(|e| JobsError::WorkerError(format!("read_dir failed: {e}")))?;
            let mut files = Vec::new();
            while let Some(entry) = entries
                .next_entry()
                .await
                .map_err(|e| JobsError::WorkerError(format!("entry failed: {e}")))?
            {
                if entry.file_type().await.ok().is_some_and(|ft| ft.is_file()) {
                    files.push(entry.path());
                }
            }
            return Ok(files);
        }
    }

    Ok(Vec::new())
}

fn resolve_target_files(target_files: &serde_json::Value) -> Vec<PathBuf> {
    let files: Vec<String> = target_files
        .as_array()
        .and_then(|arr| {
            arr.iter()
                .filter_map(|v| v.get("path").or_else(|| v.get("file")))
                .filter_map(|v| v.as_str().map(str::to_owned))
                .collect::<Vec<_>>()
                .into()
        })
        .filter(|v: &Vec<_>| !v.is_empty())
        .unwrap_or_default();

    files.into_iter().map(PathBuf::from).collect()
}

fn default_client_config() -> mydia_rs_downloads::ClientConfig {
    mydia_rs_downloads::ClientConfig::default()
}

async fn stamp_imported_at(db: &DatabaseConnection, id: &UuidText) {
    let backend = db.get_database_backend();
    let now = DateTimeSecs::from(Utc::now());
    let _ = downloads::Entity::update_many()
        .col_expr(downloads::Column::ImportedAt, now.into_simple_expr(backend))
        .col_expr(downloads::Column::UpdatedAt, now.into_simple_expr(backend))
        .filter(Expr::col(downloads::Column::Id).eq((*id).into_simple_expr(backend)))
        .exec(db)
        .await;
}

async fn stamp_import_failed(db: &DatabaseConnection, id: &UuidText, reason: &str) {
    let backend = db.get_database_backend();
    let now = DateTimeSecs::from(Utc::now());
    let _ = downloads::Entity::update_many()
        .col_expr(
            downloads::Column::ImportLastError,
            Expr::value(reason.to_owned()),
        )
        .col_expr(
            downloads::Column::ImportFailedAt,
            now.into_simple_expr(backend),
        )
        .col_expr(downloads::Column::UpdatedAt, now.into_simple_expr(backend))
        .filter(Expr::col(downloads::Column::Id).eq((*id).into_simple_expr(backend)))
        .exec(db)
        .await;
}
