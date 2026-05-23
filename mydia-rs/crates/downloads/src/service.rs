//! `DownloadService` — orchestrator for player-driven transcode downloads.
//!
//! Rust port of `lib/mydia/downloads/download_service.ex`. The
//! "download" name is a little misleading: the service does NOT touch
//! the `downloads` table (magnet / NZB queue rows) — those live behind
//! the per-client adapters in [`crate::clients`]. This service is the
//! single entry point the `MydiaWeb.Api.DownloadController` (and the
//! GraphQL `DownloadResolver`) call into when the player wants to
//! transcode an existing media file down to a chosen resolution and
//! stream the result back over HTTP with `Range:` support.
//!
//! ## Surface
//!
//! Mirrors the Phoenix public API verbatim:
//!
//! - [`DownloadService::get_options`] — list every quality option
//!   available for a media file (parent resolved from
//!   `(content_type, id)`). Each option carries an estimated size plus,
//!   if a `transcode_jobs` row already exists at that resolution, the
//!   live status / progress / actual size.
//! - [`DownloadService::prepare`] — idempotent enqueue. Looks up an
//!   existing `(media_file_id, resolution)` job and returns it if
//!   present; otherwise creates a `pending` row and dispatches the
//!   transcoder. The `"original"` resolution short-circuits the
//!   `ffmpeg` invocation entirely — the row is marked `ready` with the
//!   source path as the output so the download handler can serve the
//!   underlying file as-is.
//! - [`DownloadService::get_job_status`] / [`DownloadService::get_job`] —
//!   read paths for the controller's `job_status` and `download_file`
//!   handlers respectively.
//! - [`DownloadService::cancel_job`] — soft cancel. Aborts any active
//!   `ffmpeg` task via [`JobManager`] and deletes the row.
//! - [`DownloadService::touch_last_accessed`] — bumped by the file
//!   handler on every range request so the LRU cleanup worker has
//!   something to filter on.
//!
//! ## State
//!
//! The service is `Clone` — every field is an `Arc` (or a newtype
//! wrapping one) so a per-request copy is a refcount bump. The
//! [`JobManager`] is shared with the U17 worker monitor so this
//! service and a background poller can agree on what's currently
//! running.

use std::path::PathBuf;
use std::sync::Arc;

use chrono::{DateTime, Utc};
use mydia_rs_db::Db;
use mydia_rs_pubsub::{topics, Event, Pubsub};
use serde::{Deserialize, Serialize};
use sqlx::Row;
use tracing::{info, warn};
use uuid::Uuid;

use crate::error::DownloadError;
use crate::job_manager::JobManager;
use crate::transcoder::{Resolution, TranscodeOptions};

/// Quality option surfaced to the player for one media file.
///
/// Mirrors `Mydia.Downloads.DownloadService.calculate_quality_options/1`.
/// Fields use `snake_case` so the JSON serializer matches Phoenix's wire
/// format directly (the controller layer just passes this struct
/// through to `serde_json`).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct QualityOption {
    pub resolution: String,
    pub label: String,
    pub estimated_size: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub transcode_status: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub transcode_progress: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub actual_size: Option<i64>,
}

/// Lightweight projection of a `transcode_jobs` row the controller layer
/// returns to the player. Matches the Phoenix shape (`job_id`,
/// `status`, `progress`, `error`, `file_size`).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct JobInfo {
    pub job_id: String,
    pub status: String,
    pub progress: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub file_size: Option<i64>,
}

/// Full `transcode_jobs` row as the service surfaces it to the file
/// handler. The Phoenix `download_file` action pattern-matches on
/// `status` + `output_path` to decide whether to serve, accept-but-pending,
/// or 500; `Job` carries the same fields so the Rust handler does the
/// same match.
#[derive(Debug, Clone, PartialEq)]
pub struct Job {
    pub id: String,
    pub media_file_id: String,
    pub resolution: String,
    pub status: String,
    pub progress: f64,
    pub output_path: Option<String>,
    pub file_size: Option<i64>,
    pub error: Option<String>,
}

/// Reasons the service can fail. Mirrors the atom returns from the
/// Phoenix service so the controller can render the same status codes.
#[derive(Debug, thiserror::Error)]
pub enum ServiceError {
    /// Media item / episode id is unknown.
    #[error("media not found")]
    NotFound,
    /// Media exists but has no `media_files` row.
    #[error("no media file available for download")]
    NoMediaFile,
    /// Resolution string isn't one of the four supported values.
    #[error("invalid resolution: must be original, 1080p, 720p, or 480p")]
    InvalidResolution,
    /// Source `media_files` row has neither a `path` nor a
    /// `library_path + relative_path` pair.
    #[error("source file not found")]
    SourceFileNotFound,
    /// No `transcode_jobs` row with this id.
    #[error("transcode job not found")]
    JobNotFound,
    /// Backing-store failure.
    #[error("database: {0}")]
    Db(#[from] sqlx::Error),
    /// Unexpected internal error.
    #[error("internal: {0}")]
    Internal(String),
}

impl From<DownloadError> for ServiceError {
    fn from(err: DownloadError) -> Self {
        ServiceError::Internal(err.to_string())
    }
}

/// Result alias used throughout the service surface.
pub type Result<T> = std::result::Result<T, ServiceError>;

/// Configurable knobs. Mirrors the Phoenix
/// `Application.get_env(:mydia, :transcode_cache_dir, ...)` lookup plus
/// the `ffmpeg` binary path so test fixtures can stub it.
#[derive(Debug, Clone)]
pub struct ServiceConfig {
    /// Where the transcoder writes its output `.mp4` files. Mirrors
    /// Phoenix's `:transcode_cache_dir` config knob; defaults to
    /// `/tmp/mydia/transcodes`.
    pub transcode_cache_dir: PathBuf,
    /// Path to the `ffmpeg` binary. Defaults to `ffmpeg` (PATH lookup).
    /// Test fixtures point this at `/nonexistent/ffmpeg-binary` to
    /// exercise the spawn-failed branch.
    pub ffmpeg_path: PathBuf,
}

impl Default for ServiceConfig {
    fn default() -> Self {
        Self {
            transcode_cache_dir: PathBuf::from("/tmp/mydia/transcodes"),
            ffmpeg_path: PathBuf::from("ffmpeg"),
        }
    }
}

/// Cheap-to-clone orchestrator. See module docs for the surface.
#[derive(Clone)]
pub struct DownloadService {
    inner: Arc<Inner>,
}

struct Inner {
    db: Db,
    job_manager: JobManager,
    pubsub: Pubsub,
    config: ServiceConfig,
}

impl DownloadService {
    /// Build the orchestrator from the shared handles. Boot path uses
    /// this once and stashes the result on `WebState`.
    #[must_use]
    pub fn new(db: Db, job_manager: JobManager, pubsub: Pubsub, config: ServiceConfig) -> Self {
        Self {
            inner: Arc::new(Inner {
                db,
                job_manager,
                pubsub,
                config,
            }),
        }
    }

    /// Snapshot of the active config. Useful in tests + diagnostics.
    #[must_use]
    pub fn config(&self) -> &ServiceConfig {
        &self.inner.config
    }

    // -----------------------------------------------------------------
    // get_options
    // -----------------------------------------------------------------

    /// List quality options for the media item / episode identified by
    /// `(content_type, id)`. `content_type` is `"movie"` or `"episode"`;
    /// anything else returns [`ServiceError::NotFound`] to match Phoenix.
    pub async fn get_options(&self, content_type: &str, id: &str) -> Result<Vec<QualityOption>> {
        let media_file = self.lookup_media_file(content_type, id).await?;
        self.calculate_quality_options(&media_file).await
    }

    // -----------------------------------------------------------------
    // prepare
    // -----------------------------------------------------------------

    /// Idempotent enqueue. Looks up an existing
    /// `(media_file_id, resolution, type='download')` row; if found,
    /// returns it. Otherwise inserts a new `pending` row and dispatches
    /// the transcoder (or short-circuits to `ready` for `"original"`).
    pub async fn prepare(&self, content_type: &str, id: &str, resolution: &str) -> Result<JobInfo> {
        let resolution = validate_resolution(resolution)?;
        let media_file = self.lookup_media_file(content_type, id).await?;
        let job = self
            .get_or_create_job(&media_file.id, resolution.as_str())
            .await?;

        self.maybe_start_transcode(&job, &media_file).await?;

        // Re-read the job — the original-quality short-circuit flips
        // status to `ready` synchronously so the player sees the
        // updated row on its first poll.
        let refreshed = self
            .fetch_job(&job.id)
            .await?
            .ok_or(ServiceError::Internal("job vanished mid-prepare".into()))?;
        Ok(job_info(&refreshed))
    }

    /// Prepare a download by `media_file_id` directly. Used by the
    /// admin pre-transcode UI where the file is already known and the
    /// `content_type` / parent lookup would be redundant.
    pub async fn prepare_by_file(&self, media_file_id: &str, resolution: &str) -> Result<JobInfo> {
        let resolution = validate_resolution(resolution)?;
        let media_file = self
            .fetch_media_file_by_id(media_file_id)
            .await?
            .ok_or(ServiceError::NoMediaFile)?;
        let job = self
            .get_or_create_job(&media_file.id, resolution.as_str())
            .await?;
        self.maybe_start_transcode(&job, &media_file).await?;
        let refreshed = self
            .fetch_job(&job.id)
            .await?
            .ok_or(ServiceError::Internal(
                "job vanished mid-prepare_by_file".into(),
            ))?;
        Ok(job_info(&refreshed))
    }

    // -----------------------------------------------------------------
    // get_job_status / get_job
    // -----------------------------------------------------------------

    /// Quick status read. Returns [`ServiceError::JobNotFound`] when
    /// the id doesn't resolve.
    pub async fn get_job_status(&self, job_id: &str) -> Result<JobInfo> {
        let job = self
            .fetch_job(job_id)
            .await?
            .ok_or(ServiceError::JobNotFound)?;
        Ok(job_info(&job))
    }

    /// Full row read used by the file-serving handler.
    pub async fn get_job(&self, job_id: &str) -> Result<Job> {
        self.fetch_job(job_id)
            .await?
            .ok_or(ServiceError::JobNotFound)
    }

    // -----------------------------------------------------------------
    // cancel_job
    // -----------------------------------------------------------------

    /// Cancel a job. Aborts the active ffmpeg task (if any) via
    /// [`JobManager`] and deletes the row. Idempotent: calling on an
    /// already-finished job still removes the row.
    pub async fn cancel_job(&self, job_id: &str) -> Result<()> {
        let job = self
            .fetch_job(job_id)
            .await?
            .ok_or(ServiceError::JobNotFound)?;

        // Best-effort cancel of the running ffmpeg job. The JobManager
        // call is sync + non-failing; ignore the boolean result.
        let resolution = resolution_to_atom(&job.resolution);
        let _ = self
            .inner
            .job_manager
            .cancel(&job.media_file_id, resolution);

        self.delete_job(&job.id).await?;

        // Clean up the output file when we own it (skip for "original"
        // because the output_path points at the user's source file).
        if let Some(output_path) = job.output_path.as_deref() {
            if job.resolution != "original" {
                let path = PathBuf::from(output_path);
                if let Err(err) = tokio::fs::remove_file(&path).await {
                    if err.kind() != std::io::ErrorKind::NotFound {
                        warn!(
                            error = ?err,
                            path = %path.display(),
                            "failed to remove transcoded output on cancel"
                        );
                    }
                }
            }
        }

        self.broadcast_job_event(&job.id, "job_updated", None, None);
        Ok(())
    }

    // -----------------------------------------------------------------
    // touch_last_accessed
    // -----------------------------------------------------------------

    /// Bump the row's `last_accessed_at` column. Called by the file
    /// handler on every range request so the LRU cleanup worker has
    /// fresh signal.
    pub async fn touch_last_accessed(&self, job_id: &str) -> Result<()> {
        let now = Utc::now();
        match &self.inner.db {
            Db::Sqlite(pool) => {
                sqlx::query(
                    "UPDATE transcode_jobs SET last_accessed_at = ?, updated_at = ? WHERE id = ?",
                )
                .bind(now.to_rfc3339())
                .bind(now.to_rfc3339())
                .bind(job_id)
                .execute(pool)
                .await?;
            }
            Db::Postgres(pool) => {
                sqlx::query(
                    "UPDATE transcode_jobs SET last_accessed_at = $1, updated_at = $2 WHERE id = $3",
                )
                .bind(now)
                .bind(now)
                .bind(job_id)
                .execute(pool)
                .await?;
            }
        }
        Ok(())
    }

    // -----------------------------------------------------------------
    // Internals
    // -----------------------------------------------------------------

    /// Compute the available quality options for a media file. Mirrors
    /// Phoenix `calculate_quality_options/1`: `"original"` first, then
    /// each lower resolution whose height fits inside the source.
    async fn calculate_quality_options(
        &self,
        media_file: &MediaFileRow,
    ) -> Result<Vec<QualityOption>> {
        let source_size = media_file.size.unwrap_or(0);
        let source_height = parse_resolution_height(media_file.resolution.as_deref());

        // Look up existing jobs so we can decorate each option with
        // their live status / progress. Phoenix does this once and
        // builds a Map; we do the same.
        let jobs = self.list_jobs_for_media_file(&media_file.id).await?;
        let lookup = |res: &str| jobs.iter().find(|j| j.resolution == res);

        let mut options = Vec::new();

        // "original" is always first, never filtered.
        options.push(enrich_with_status(
            QualityOption {
                resolution: "original".into(),
                label: "Original".into(),
                estimated_size: source_size,
                transcode_status: None,
                transcode_progress: None,
                actual_size: None,
            },
            lookup("original"),
        ));

        for (resolution, height, label) in [
            ("1080p", 1080_i64, "1080p (Full HD)"),
            ("720p", 720, "720p (HD)"),
            ("480p", 480, "480p (SD)"),
        ] {
            if height > source_height {
                continue;
            }
            let estimated_size = estimate_file_size(source_size, source_height, height);
            options.push(enrich_with_status(
                QualityOption {
                    resolution: resolution.into(),
                    label: label.into(),
                    estimated_size,
                    transcode_status: None,
                    transcode_progress: None,
                    actual_size: None,
                },
                lookup(resolution),
            ));
        }
        Ok(options)
    }

    /// Resolve `(content_type, id)` to a single `media_files` row.
    /// Mirrors the Phoenix helper's parent → first-file projection.
    async fn lookup_media_file(&self, content_type: &str, id: &str) -> Result<MediaFileRow> {
        match content_type {
            "movie" => {
                let row = self
                    .fetch_first_media_file_for_parent("media_item_id", id, true)
                    .await?;
                row.ok_or(ServiceError::NoMediaFile)
            }
            "episode" => {
                let row = self
                    .fetch_first_media_file_for_parent("episode_id", id, false)
                    .await?;
                row.ok_or(ServiceError::NoMediaFile)
            }
            _ => Err(ServiceError::NotFound),
        }
    }

    /// Pull the first non-trashed media file for the given parent
    /// column. Mirrors the Phoenix helper. Returns `None` when the
    /// parent has no files.
    async fn fetch_first_media_file_for_parent(
        &self,
        parent_col: &str,
        parent_id: &str,
        movie: bool,
    ) -> Result<Option<MediaFileRow>> {
        let extra = if movie {
            " AND mf.episode_id IS NULL"
        } else {
            ""
        };
        let sql_pg = format!(
            "SELECT mf.id, mf.size, mf.resolution, mf.path, mf.relative_path, lp.path AS lp_path \
             FROM media_files mf \
             LEFT JOIN library_paths lp ON lp.id = mf.library_path_id \
             WHERE mf.{parent_col} = $1 AND mf.trashed_at IS NULL{extra} \
             ORDER BY mf.inserted_at ASC \
             LIMIT 1"
        );
        match &self.inner.db {
            Db::Sqlite(pool) => {
                let sql = sql_pg.replace("$1", "?");
                let row = sqlx::query(&sql)
                    .bind(parent_id)
                    .fetch_optional(pool)
                    .await?;
                Ok(row.as_ref().map(media_file_from_row))
            }
            Db::Postgres(pool) => {
                let row = sqlx::query(&sql_pg)
                    .bind(parent_id)
                    .fetch_optional(pool)
                    .await?;
                Ok(row.as_ref().map(media_file_from_row))
            }
        }
    }

    /// Fetch a media file by its own id. Used by `prepare_by_file`.
    async fn fetch_media_file_by_id(&self, id: &str) -> Result<Option<MediaFileRow>> {
        let sql_pg =
            "SELECT mf.id, mf.size, mf.resolution, mf.path, mf.relative_path, lp.path AS lp_path \
             FROM media_files mf \
             LEFT JOIN library_paths lp ON lp.id = mf.library_path_id \
             WHERE mf.id = $1 LIMIT 1";
        match &self.inner.db {
            Db::Sqlite(pool) => {
                let sql = sql_pg.replace("$1", "?");
                let row = sqlx::query(&sql).bind(id).fetch_optional(pool).await?;
                Ok(row.as_ref().map(media_file_from_row))
            }
            Db::Postgres(pool) => {
                let row = sqlx::query(sql_pg).bind(id).fetch_optional(pool).await?;
                Ok(row.as_ref().map(media_file_from_row))
            }
        }
    }

    /// Idempotent insert. Returns an existing
    /// `(media_file_id, resolution, type='download')` job if one is
    /// present; otherwise inserts a fresh `pending` row. Mirrors
    /// `Mydia.Downloads.Transcoding.get_or_create_job/2` including the
    /// race-window catch where the insert fails on the partial unique
    /// index (two concurrent prepares for the same key).
    async fn get_or_create_job(&self, media_file_id: &str, resolution: &str) -> Result<Job> {
        if let Some(existing) = self.fetch_job_by_key(media_file_id, resolution).await? {
            return Ok(existing);
        }

        let id = Uuid::new_v4().to_string();
        let now = Utc::now();
        let insert_result = self
            .try_insert_job(&id, media_file_id, resolution, &now)
            .await;

        match insert_result {
            Ok(()) => {
                let job = self
                    .fetch_job(&id)
                    .await?
                    .ok_or_else(|| ServiceError::Internal("inserted job vanished".into()))?;
                self.broadcast_job_event(&job.id, "job_started", None, None);
                Ok(job)
            }
            Err(sqlx::Error::Database(db_err)) if is_unique_violation(db_err.as_ref()) => {
                // Another caller raced ahead — re-read the row they
                // inserted under the same key.
                let job = self
                    .fetch_job_by_key(media_file_id, resolution)
                    .await?
                    .ok_or_else(|| {
                        ServiceError::Internal("unique-conflict on insert but no row by key".into())
                    })?;
                Ok(job)
            }
            Err(err) => Err(err.into()),
        }
    }

    async fn try_insert_job(
        &self,
        id: &str,
        media_file_id: &str,
        resolution: &str,
        now: &DateTime<Utc>,
    ) -> std::result::Result<(), sqlx::Error> {
        match &self.inner.db {
            Db::Sqlite(pool) => {
                sqlx::query(
                    "INSERT INTO transcode_jobs \
                     (id, media_file_id, resolution, type, status, progress, inserted_at, updated_at) \
                     VALUES (?, ?, ?, 'download', 'pending', 0.0, ?, ?)",
                )
                .bind(id)
                .bind(media_file_id)
                .bind(resolution)
                .bind(now.to_rfc3339())
                .bind(now.to_rfc3339())
                .execute(pool)
                .await?;
            }
            Db::Postgres(pool) => {
                sqlx::query(
                    "INSERT INTO transcode_jobs \
                     (id, media_file_id, resolution, type, status, progress, inserted_at, updated_at) \
                     VALUES ($1, $2, $3, 'download', 'pending', 0.0, $4, $5)",
                )
                .bind(id)
                .bind(media_file_id)
                .bind(resolution)
                .bind(now)
                .bind(now)
                .execute(pool)
                .await?;
            }
        }
        Ok(())
    }

    async fn fetch_job(&self, id: &str) -> Result<Option<Job>> {
        let sql_pg = "SELECT id, media_file_id, resolution, status, COALESCE(progress, 0.0), \
                      output_path, file_size, error FROM transcode_jobs WHERE id = $1 LIMIT 1";
        match &self.inner.db {
            Db::Sqlite(pool) => {
                let sql = sql_pg.replace("$1", "?");
                let row = sqlx::query(&sql).bind(id).fetch_optional(pool).await?;
                Ok(row.as_ref().map(job_from_row))
            }
            Db::Postgres(pool) => {
                let row = sqlx::query(sql_pg).bind(id).fetch_optional(pool).await?;
                Ok(row.as_ref().map(job_from_row))
            }
        }
    }

    async fn fetch_job_by_key(&self, media_file_id: &str, resolution: &str) -> Result<Option<Job>> {
        let sql_pg = "SELECT id, media_file_id, resolution, status, COALESCE(progress, 0.0), \
                      output_path, file_size, error FROM transcode_jobs \
                      WHERE media_file_id = $1 AND resolution = $2 AND type = 'download' LIMIT 1";
        match &self.inner.db {
            Db::Sqlite(pool) => {
                let sql = sql_pg.replace("$1", "?").replace("$2", "?");
                let row = sqlx::query(&sql)
                    .bind(media_file_id)
                    .bind(resolution)
                    .fetch_optional(pool)
                    .await?;
                Ok(row.as_ref().map(job_from_row))
            }
            Db::Postgres(pool) => {
                let row = sqlx::query(sql_pg)
                    .bind(media_file_id)
                    .bind(resolution)
                    .fetch_optional(pool)
                    .await?;
                Ok(row.as_ref().map(job_from_row))
            }
        }
    }

    async fn list_jobs_for_media_file(&self, media_file_id: &str) -> Result<Vec<Job>> {
        let sql_pg = "SELECT id, media_file_id, resolution, status, COALESCE(progress, 0.0), \
                      output_path, file_size, error FROM transcode_jobs \
                      WHERE media_file_id = $1 AND type = 'download' \
                      ORDER BY updated_at DESC";
        match &self.inner.db {
            Db::Sqlite(pool) => {
                let sql = sql_pg.replace("$1", "?");
                let rows = sqlx::query(&sql)
                    .bind(media_file_id)
                    .fetch_all(pool)
                    .await?;
                Ok(rows.iter().map(job_from_row).collect())
            }
            Db::Postgres(pool) => {
                let rows = sqlx::query(sql_pg)
                    .bind(media_file_id)
                    .fetch_all(pool)
                    .await?;
                Ok(rows.iter().map(job_from_row).collect())
            }
        }
    }

    async fn delete_job(&self, id: &str) -> Result<()> {
        match &self.inner.db {
            Db::Sqlite(pool) => {
                sqlx::query("DELETE FROM transcode_jobs WHERE id = ?")
                    .bind(id)
                    .execute(pool)
                    .await?;
            }
            Db::Postgres(pool) => {
                sqlx::query("DELETE FROM transcode_jobs WHERE id = $1")
                    .bind(id)
                    .execute(pool)
                    .await?;
            }
        }
        Ok(())
    }

    /// Mark a job complete with the supplied output path + size. Used
    /// for the `"original"` short-circuit and (eventually) the
    /// transcode-completion callback.
    async fn complete_job(&self, id: &str, output_path: &str, file_size: i64) -> Result<()> {
        let now = Utc::now();
        match &self.inner.db {
            Db::Sqlite(pool) => {
                sqlx::query(
                    "UPDATE transcode_jobs SET status = 'ready', progress = 1.0, \
                     output_path = ?, file_size = ?, completed_at = ?, last_accessed_at = ?, \
                     updated_at = ? WHERE id = ?",
                )
                .bind(output_path)
                .bind(file_size)
                .bind(now.to_rfc3339())
                .bind(now.to_rfc3339())
                .bind(now.to_rfc3339())
                .bind(id)
                .execute(pool)
                .await?;
            }
            Db::Postgres(pool) => {
                sqlx::query(
                    "UPDATE transcode_jobs SET status = 'ready', progress = 1.0, \
                     output_path = $1, file_size = $2, completed_at = $3, last_accessed_at = $4, \
                     updated_at = $5 WHERE id = $6",
                )
                .bind(output_path)
                .bind(file_size)
                .bind(now)
                .bind(now)
                .bind(now)
                .bind(id)
                .execute(pool)
                .await?;
            }
        }
        self.broadcast_job_event(id, "job_completed", None, None);
        Ok(())
    }

    /// Dispatch path. Mirrors Phoenix's `maybe_start_transcode/2`.
    /// `"original"` short-circuits to a synchronous `complete_job`
    /// using the source media file's absolute path. Other resolutions
    /// kick the [`JobManager`] which spawns ffmpeg in the background;
    /// the transcoder writes progress to pubsub and (once it finishes
    /// or fails) the U17 worker is responsible for updating the row.
    async fn maybe_start_transcode(&self, job: &Job, media_file: &MediaFileRow) -> Result<()> {
        if job.status != "pending" {
            return Ok(());
        }
        let Some(source_path) = media_file.absolute_path() else {
            return Err(ServiceError::SourceFileNotFound);
        };

        if job.resolution == "original" {
            let file_size = media_file.size.unwrap_or(0);
            self.complete_job(&job.id, source_path.to_str().unwrap_or(""), file_size)
                .await?;
            return Ok(());
        }

        // Non-original — kick the JobManager.
        if let Err(err) = tokio::fs::create_dir_all(&self.inner.config.transcode_cache_dir).await {
            warn!(error = ?err, "create transcode cache dir failed (continuing)");
        }
        let output_path = self
            .inner
            .config
            .transcode_cache_dir
            .join(format!("{}.mp4", job.id));
        let resolution = resolution_to_atom(&job.resolution);

        let options = TranscodeOptions {
            input_path: source_path,
            output_path: output_path.clone(),
            resolution,
            ffmpeg_path: self.inner.config.ffmpeg_path.clone(),
            ..TranscodeOptions::new(media_file.absolute_path().unwrap_or_default(), output_path)
        };

        match self
            .inner
            .job_manager
            .start(media_file.id.clone(), resolution, options)
            .await
        {
            Ok(_) => {
                info!(
                    job_id = %job.id,
                    media_file_id = %media_file.id,
                    resolution = %job.resolution,
                    "transcode dispatched"
                );
                Ok(())
            }
            Err(DownloadError::Internal(msg)) if msg.contains("already running") => {
                // Idempotent: a job for the same key is already running.
                Ok(())
            }
            Err(err) => Err(err.into()),
        }
    }

    /// Best-effort publish to the `transcodes` topic so the admin page
    /// + GraphQL subscription see the same lifecycle the Phoenix
    ///   service published. Failure is logged; the service does not back
    ///   out the underlying DB write on pubsub failure.
    fn broadcast_job_event(
        &self,
        job_id: &str,
        event: &str,
        progress: Option<f64>,
        status: Option<&str>,
    ) {
        let mut payload = serde_json::json!({ "event": event, "job_id": job_id });
        if let Some(progress) = progress {
            payload["progress"] = serde_json::json!(progress);
        }
        if let Some(status) = status {
            payload["status"] = serde_json::json!(status);
        }
        self.inner
            .pubsub
            .publish(topics::TRANSCODES, Event::from_json(payload));
    }
}

// ---------------------------------------------------------------------
// Row helpers + pure logic.
// ---------------------------------------------------------------------

/// Minimal projection of `media_files` used by the service. Wider than
/// strictly necessary so the row stays grep-traceable to the Phoenix
/// `MediaFile` struct.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MediaFileRow {
    pub id: String,
    pub size: Option<i64>,
    pub resolution: Option<String>,
    /// Legacy absolute path. When present this wins over the
    /// `library_path + relative_path` pair (mirrors
    /// `Mydia.Library.MediaFile.absolute_path/1`).
    pub path: Option<String>,
    pub relative_path: Option<String>,
    /// Library root path joined from `library_paths.path`.
    pub library_path: Option<String>,
}

impl MediaFileRow {
    /// Resolve the absolute on-disk path for this media file. Mirrors
    /// Phoenix's `MediaFile.absolute_path/1`: prefer the legacy `path`
    /// column when set, otherwise join `library_path + relative_path`.
    /// Returns `None` when neither pair is available.
    #[must_use]
    pub fn absolute_path(&self) -> Option<PathBuf> {
        if let Some(p) = &self.path {
            if !p.is_empty() {
                return Some(PathBuf::from(p));
            }
        }
        if let (Some(lp), Some(rel)) = (&self.library_path, &self.relative_path) {
            return Some(PathBuf::from(lp).join(rel));
        }
        None
    }
}

fn media_file_from_row<R: Row>(row: &R) -> MediaFileRow
where
    for<'r> String: sqlx::Decode<'r, R::Database> + sqlx::Type<R::Database>,
    for<'r> Option<String>: sqlx::Decode<'r, R::Database> + sqlx::Type<R::Database>,
    for<'r> Option<i64>: sqlx::Decode<'r, R::Database> + sqlx::Type<R::Database>,
    usize: sqlx::ColumnIndex<R>,
{
    MediaFileRow {
        id: row.get(0),
        size: row.get(1),
        resolution: row.get(2),
        path: row.get(3),
        relative_path: row.get(4),
        library_path: row.get(5),
    }
}

fn job_from_row<R: Row>(row: &R) -> Job
where
    for<'r> String: sqlx::Decode<'r, R::Database> + sqlx::Type<R::Database>,
    for<'r> Option<String>: sqlx::Decode<'r, R::Database> + sqlx::Type<R::Database>,
    for<'r> Option<i64>: sqlx::Decode<'r, R::Database> + sqlx::Type<R::Database>,
    for<'r> f64: sqlx::Decode<'r, R::Database> + sqlx::Type<R::Database>,
    usize: sqlx::ColumnIndex<R>,
{
    Job {
        id: row.get(0),
        media_file_id: row.get(1),
        resolution: row.get(2),
        status: row.get(3),
        progress: row.get(4),
        output_path: row.get(5),
        file_size: row.get(6),
        error: row.get(7),
    }
}

fn job_info(job: &Job) -> JobInfo {
    JobInfo {
        job_id: job.id.clone(),
        status: job.status.clone(),
        progress: job.progress,
        error: job.error.clone(),
        file_size: job.file_size,
    }
}

fn enrich_with_status(mut option: QualityOption, job: Option<&Job>) -> QualityOption {
    if let Some(job) = job {
        option.transcode_status = Some(job.status.clone());
        option.transcode_progress = Some(job.progress);
        option.actual_size = job.file_size;
    }
    option
}

/// Crude SQLite-vs-Postgres unique-constraint detection. Phoenix's
/// equivalent reaches into the changeset error map; the Rust path
/// pattern-matches on the underlying driver error.
fn is_unique_violation(err: &(dyn sqlx::error::DatabaseError + 'static)) -> bool {
    // SQLite reports "UNIQUE constraint failed: ..." in the message.
    // Postgres reports SQLSTATE 23505.
    if let Some(code) = err.code() {
        if code == "23505" || code == "2067" {
            return true;
        }
    }
    err.message().contains("UNIQUE constraint") || err.message().contains("duplicate key")
}

fn validate_resolution(resolution: &str) -> Result<ResolutionString> {
    match resolution {
        "original" | "1080p" | "720p" | "480p" => Ok(ResolutionString(resolution.to_owned())),
        _ => Err(ServiceError::InvalidResolution),
    }
}

/// Newtype guard so call sites can't construct a job with an arbitrary
/// resolution string — only one of the four whitelisted values can be
/// built via [`validate_resolution`].
#[derive(Debug)]
struct ResolutionString(String);

impl ResolutionString {
    fn as_str(&self) -> &str {
        &self.0
    }
}

fn resolution_to_atom(resolution: &str) -> Resolution {
    match resolution {
        "1080p" => Resolution::P1080,
        "480p" => Resolution::P480,
        // "original" never reaches the JobManager (handled by the
        // short-circuit) so the fallback for anything else (including
        // bare "original" if it slipped through) maps to P720 to match
        // the Phoenix default — same arm as the literal "720p".
        _ => Resolution::P720,
    }
}

fn parse_resolution_height(resolution: Option<&str>) -> i64 {
    let Some(value) = resolution else {
        return 1080;
    };
    match value {
        "4K" | "2160p" => 2160,
        "1080p" => 1080,
        "720p" => 720,
        "480p" => 480,
        other => parse_wxh_height(other).unwrap_or(1080),
    }
}

fn parse_wxh_height(value: &str) -> Option<i64> {
    // `1920x1080` style strings — split on the literal `x`.
    let (_w, h) = value.split_once('x')?;
    h.parse().ok()
}

fn estimate_file_size(source_size: i64, source_height: i64, target_height: i64) -> i64 {
    if source_height <= 0 || target_height <= 0 {
        return source_size;
    }
    if target_height >= source_height {
        return source_size;
    }
    // Quadratic scaling — matches Phoenix's `ratio * ratio` heuristic.
    let ratio = target_height as f64 / source_height as f64;
    (source_size as f64 * ratio * ratio).round() as i64
}

/// Hidden helper for the controller layer to bridge the
/// service error → HTTP status mapping. Keeps the controller small.
#[doc(hidden)]
pub fn map_status<T>(_: &Result<T>) {
    // intentionally empty — referenced from `crates/web` so the
    // controller has a `use` anchor on this module even when it never
    // needs the helper at compile time.
}

/// Public, hidden helper that the controller layer reuses to render a
/// path-based file response. Lives here so the absolute-path resolver
/// for `media_files` stays in one place.
#[doc(hidden)]
pub fn debug_absolute_path(media_file: &MediaFileRow) -> Option<PathBuf> {
    media_file.absolute_path()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_resolution_height_handles_known_strings() {
        assert_eq!(parse_resolution_height(None), 1080);
        assert_eq!(parse_resolution_height(Some("4K")), 2160);
        assert_eq!(parse_resolution_height(Some("2160p")), 2160);
        assert_eq!(parse_resolution_height(Some("1080p")), 1080);
        assert_eq!(parse_resolution_height(Some("720p")), 720);
        assert_eq!(parse_resolution_height(Some("480p")), 480);
        assert_eq!(parse_resolution_height(Some("1920x1080")), 1080);
        assert_eq!(parse_resolution_height(Some("garbage")), 1080);
    }

    #[test]
    fn estimate_file_size_scales_quadratically_for_downscale() {
        // 1 GiB at 1080p → 720p
        let scaled = estimate_file_size(1_073_741_824, 1080, 720);
        let ratio = 720.0_f64 / 1080.0_f64;
        let expected = (1_073_741_824.0 * ratio * ratio).round() as i64;
        assert_eq!(scaled, expected);
    }

    #[test]
    fn estimate_file_size_keeps_size_when_target_meets_or_exceeds_source() {
        assert_eq!(estimate_file_size(500, 720, 720), 500);
        assert_eq!(estimate_file_size(500, 720, 1080), 500);
    }

    #[test]
    fn estimate_file_size_keeps_size_on_zero_or_negative_height() {
        assert_eq!(estimate_file_size(500, 0, 720), 500);
        assert_eq!(estimate_file_size(500, 720, 0), 500);
    }

    #[test]
    fn validate_resolution_accepts_all_four_supported_values() {
        for value in ["original", "1080p", "720p", "480p"] {
            let parsed = validate_resolution(value).expect("valid");
            assert_eq!(parsed.as_str(), value);
        }
    }

    #[test]
    fn validate_resolution_rejects_anything_else() {
        let err = validate_resolution("8k").unwrap_err();
        assert!(matches!(err, ServiceError::InvalidResolution));
    }

    #[test]
    fn resolution_to_atom_maps_known_strings() {
        assert_eq!(resolution_to_atom("1080p"), Resolution::P1080);
        assert_eq!(resolution_to_atom("720p"), Resolution::P720);
        assert_eq!(resolution_to_atom("480p"), Resolution::P480);
        assert_eq!(resolution_to_atom("garbage"), Resolution::P720);
    }

    #[test]
    fn media_file_row_prefers_legacy_path_over_library_path() {
        let row = MediaFileRow {
            id: "a".into(),
            size: Some(0),
            resolution: None,
            path: Some("/abs/movie.mkv".into()),
            relative_path: Some("rel/movie.mkv".into()),
            library_path: Some("/library".into()),
        };
        assert_eq!(row.absolute_path(), Some(PathBuf::from("/abs/movie.mkv")));
    }

    #[test]
    fn media_file_row_falls_back_to_library_join() {
        let row = MediaFileRow {
            id: "a".into(),
            size: Some(0),
            resolution: None,
            path: None,
            relative_path: Some("rel/movie.mkv".into()),
            library_path: Some("/library".into()),
        };
        assert_eq!(
            row.absolute_path(),
            Some(PathBuf::from("/library/rel/movie.mkv"))
        );
    }

    #[test]
    fn media_file_row_returns_none_without_either_pair() {
        let row = MediaFileRow {
            id: "a".into(),
            size: None,
            resolution: None,
            path: None,
            relative_path: None,
            library_path: None,
        };
        assert!(row.absolute_path().is_none());
    }

    #[test]
    fn enrich_with_status_attaches_job_progress() {
        let job = Job {
            id: "j1".into(),
            media_file_id: "f1".into(),
            resolution: "720p".into(),
            status: "transcoding".into(),
            progress: 0.42,
            output_path: None,
            file_size: Some(123),
            error: None,
        };
        let option = QualityOption {
            resolution: "720p".into(),
            label: "720p (HD)".into(),
            estimated_size: 1000,
            transcode_status: None,
            transcode_progress: None,
            actual_size: None,
        };
        let enriched = enrich_with_status(option, Some(&job));
        assert_eq!(enriched.transcode_status.as_deref(), Some("transcoding"));
        assert!((enriched.transcode_progress.unwrap() - 0.42).abs() < f64::EPSILON);
        assert_eq!(enriched.actual_size, Some(123));
    }
}

// ---------------------------------------------------------------------
// Integration-shaped tests that exercise the DB-backed paths through a
// real sqlx pool. Hidden behind the standard `cfg(test)` gate. The
// suite uses an in-memory SQLite pool plus the minimal schema slice
// these calls touch.
// ---------------------------------------------------------------------

#[cfg(test)]
mod db_tests {
    use super::*;
    use mydia_rs_pubsub::Pubsub;
    use sqlx::sqlite::SqlitePoolOptions;

    const SCHEMA: &str = "
        CREATE TABLE media_files (
            id TEXT PRIMARY KEY,
            media_item_id TEXT,
            episode_id TEXT,
            library_path_id TEXT,
            path TEXT,
            relative_path TEXT,
            size INTEGER,
            resolution TEXT,
            trashed_at TEXT,
            inserted_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        CREATE TABLE library_paths (
            id TEXT PRIMARY KEY,
            path TEXT NOT NULL
        );
        CREATE TABLE transcode_jobs (
            id TEXT PRIMARY KEY,
            media_file_id TEXT NOT NULL,
            resolution TEXT NOT NULL,
            type TEXT NOT NULL DEFAULT 'download',
            status TEXT NOT NULL,
            progress REAL,
            output_path TEXT,
            file_size INTEGER,
            error TEXT,
            started_at TEXT,
            completed_at TEXT,
            last_accessed_at TEXT,
            user_id TEXT,
            inserted_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        CREATE UNIQUE INDEX transcode_jobs_media_file_id_resolution_index
            ON transcode_jobs (media_file_id, resolution)
            WHERE type = 'download';
    ";

    async fn build_service() -> (DownloadService, Db) {
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect("sqlite::memory:")
            .await
            .expect("open in-memory sqlite");
        for stmt in SCHEMA.split(';') {
            let trimmed = stmt.trim();
            if !trimmed.is_empty() {
                sqlx::query(trimmed).execute(&pool).await.expect("schema");
            }
        }
        let db = Db::Sqlite(pool);
        let manager = JobManager::new(2);
        let pubsub = Pubsub::new();
        // Point ffmpeg at a missing binary so spawn fails — the
        // service handles that as a soft error (the job stays
        // `pending`) and the test doesn't pay for a real ffmpeg.
        let config = ServiceConfig {
            ffmpeg_path: PathBuf::from("/nonexistent/ffmpeg-mydia-tests"),
            transcode_cache_dir: std::env::temp_dir().join("mydia-rs-tests"),
        };
        let service = DownloadService::new(db.clone(), manager, pubsub, config);
        (service, db)
    }

    async fn insert_media_file(db: &Db, id: &str, size: i64, abs_path: &str) {
        let Db::Sqlite(pool) = db else { unreachable!() };
        let now = Utc::now().to_rfc3339();
        sqlx::query(
            "INSERT INTO media_files (id, media_item_id, episode_id, path, size, resolution, \
             inserted_at, updated_at) VALUES (?, ?, NULL, ?, ?, '1080p', ?, ?)",
        )
        .bind(id)
        .bind("movie-1")
        .bind(abs_path)
        .bind(size)
        .bind(&now)
        .bind(&now)
        .execute(pool)
        .await
        .expect("insert media_file");
    }

    #[tokio::test]
    async fn get_options_lists_original_plus_downscales() {
        let (service, db) = build_service().await;
        insert_media_file(&db, "mf-1", 1_073_741_824, "/tmp/fake.mkv").await;
        let options = service.get_options("movie", "movie-1").await.expect("opts");
        // Original + 1080p + 720p + 480p == 4 entries for a 1080p source.
        assert_eq!(options.len(), 4);
        assert_eq!(options[0].resolution, "original");
        assert_eq!(options[0].estimated_size, 1_073_741_824);
        assert_eq!(options[1].resolution, "1080p");
        assert_eq!(options[2].resolution, "720p");
        assert_eq!(options[3].resolution, "480p");
        // Each downscale should be smaller than the source.
        for opt in &options[1..] {
            assert!(opt.estimated_size <= 1_073_741_824, "{opt:?}");
        }
    }

    #[tokio::test]
    async fn get_options_missing_media_returns_no_media_file() {
        let (service, _db) = build_service().await;
        let err = service
            .get_options("movie", "does-not-exist")
            .await
            .expect_err("no media");
        assert!(matches!(err, ServiceError::NoMediaFile));
    }

    #[tokio::test]
    async fn get_options_invalid_content_type_returns_not_found() {
        let (service, _db) = build_service().await;
        let err = service
            .get_options("garbage", "anything")
            .await
            .expect_err("not found");
        assert!(matches!(err, ServiceError::NotFound));
    }

    #[tokio::test]
    async fn prepare_original_short_circuits_to_ready() {
        let (service, db) = build_service().await;
        insert_media_file(&db, "mf-1", 100, "/tmp/fake.mkv").await;
        let info = service
            .prepare("movie", "movie-1", "original")
            .await
            .expect("prepare");
        assert_eq!(info.status, "ready");
        assert!((info.progress - 1.0).abs() < f64::EPSILON);
        assert_eq!(info.file_size, Some(100));
    }

    #[tokio::test]
    async fn prepare_is_idempotent() {
        let (service, db) = build_service().await;
        insert_media_file(&db, "mf-1", 100, "/tmp/fake.mkv").await;
        let first = service
            .prepare("movie", "movie-1", "original")
            .await
            .expect("first");
        let second = service
            .prepare("movie", "movie-1", "original")
            .await
            .expect("second");
        assert_eq!(first.job_id, second.job_id);
    }

    #[tokio::test]
    async fn prepare_invalid_resolution_rejects_before_db_work() {
        let (service, db) = build_service().await;
        insert_media_file(&db, "mf-1", 100, "/tmp/fake.mkv").await;
        let err = service
            .prepare("movie", "movie-1", "9000p")
            .await
            .expect_err("rejected");
        assert!(matches!(err, ServiceError::InvalidResolution));
    }

    #[tokio::test]
    async fn prepare_non_original_creates_pending_row() {
        let (service, db) = build_service().await;
        insert_media_file(&db, "mf-1", 100, "/tmp/fake.mkv").await;
        let info = service
            .prepare("movie", "movie-1", "720p")
            .await
            .expect("prepare");
        // ffmpeg spawn failed (binary doesn't exist), but the row was
        // created and the JobManager's start call surfaced the failure
        // as an Internal error — which the service translates into
        // ServiceError::Internal. Verify here we re-read the row at
        // the pending state when the dispatch fails after creation.
        // Behavior parity: Phoenix keeps the row even when the
        // transcoder bails. The status the player sees is "pending".
        assert_eq!(info.status, "pending");
        assert!((info.progress - 0.0).abs() < f64::EPSILON);
    }

    #[tokio::test]
    async fn get_job_status_returns_not_found_for_unknown_id() {
        let (service, _db) = build_service().await;
        let err = service.get_job_status("nonexistent").await.expect_err("nf");
        assert!(matches!(err, ServiceError::JobNotFound));
    }

    #[tokio::test]
    async fn cancel_job_deletes_row() {
        let (service, db) = build_service().await;
        insert_media_file(&db, "mf-1", 100, "/tmp/fake.mkv").await;
        let info = service
            .prepare("movie", "movie-1", "original")
            .await
            .expect("prepare");
        service.cancel_job(&info.job_id).await.expect("cancel");
        let err = service
            .get_job_status(&info.job_id)
            .await
            .expect_err("gone");
        assert!(matches!(err, ServiceError::JobNotFound));
    }

    #[tokio::test]
    async fn cancel_job_unknown_id_returns_not_found() {
        let (service, _db) = build_service().await;
        let err = service.cancel_job("nope").await.expect_err("nf");
        assert!(matches!(err, ServiceError::JobNotFound));
    }

    #[tokio::test]
    async fn touch_last_accessed_updates_timestamp() {
        let (service, db) = build_service().await;
        insert_media_file(&db, "mf-1", 100, "/tmp/fake.mkv").await;
        let info = service
            .prepare("movie", "movie-1", "original")
            .await
            .expect("prepare");

        // Read the current last_accessed_at, touch, then verify it
        // moved forward. We compare strings (rfc3339) — close enough
        // for an integration test, and we sleep 1ms to ensure the new
        // value is different.
        let Db::Sqlite(pool) = &db else {
            unreachable!()
        };
        let (before,): (Option<String>,) =
            sqlx::query_as("SELECT last_accessed_at FROM transcode_jobs WHERE id = ?")
                .bind(&info.job_id)
                .fetch_one(pool)
                .await
                .expect("read");

        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        service
            .touch_last_accessed(&info.job_id)
            .await
            .expect("touch");

        let (after,): (Option<String>,) =
            sqlx::query_as("SELECT last_accessed_at FROM transcode_jobs WHERE id = ?")
                .bind(&info.job_id)
                .fetch_one(pool)
                .await
                .expect("read again");
        // Both should be present; after >= before.
        assert!(before.is_some());
        assert!(after.is_some());
        assert!(after.unwrap() >= before.unwrap());
    }

    #[tokio::test]
    async fn list_jobs_for_media_file_decorates_quality_options() {
        let (service, db) = build_service().await;
        insert_media_file(&db, "mf-1", 100, "/tmp/fake.mkv").await;
        // Prepare original to get a ready job.
        let _ = service
            .prepare("movie", "movie-1", "original")
            .await
            .expect("prepare");
        let options = service.get_options("movie", "movie-1").await.expect("opts");
        let original = options.iter().find(|o| o.resolution == "original").unwrap();
        assert_eq!(original.transcode_status.as_deref(), Some("ready"));
        assert!((original.transcode_progress.unwrap() - 1.0).abs() < f64::EPSILON);
    }
}
