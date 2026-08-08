use chrono::Utc;

use crate::{Db, DbError};

#[derive(Debug, Clone, sqlx::FromRow)]
pub struct ScanRunRow {
    pub id: String,
    pub library_path_id: String,
    pub state: String,
    pub files_seen: i64,
    pub files_indexed: i64,
    pub files_failed: i64,
    pub started_at: String,
    pub finished_at: Option<String>,
    pub error: Option<String>,
}

#[derive(Debug, Clone, sqlx::FromRow)]
pub struct ScanIssueRow {
    pub id: String,
    pub scan_run_id: String,
    pub path: String,
    pub reason: String,
    pub detail: Option<String>,
    pub occurred_at: String,
}

const SELECT_RUN: &str = "SELECT id, library_path_id, state, files_seen, files_indexed,
                                 files_failed, started_at, finished_at, error
                          FROM scan_runs";

pub async fn start(db: &Db, library_path_id: &str) -> Result<ScanRunRow, DbError> {
    let id = uuid::Uuid::new_v4().to_string();
    let now = Utc::now().to_rfc3339();

    sqlx::query(
        "INSERT INTO scan_runs (id, library_path_id, state, started_at)
         VALUES (?, ?, 'running', ?)",
    )
    .bind(&id)
    .bind(library_path_id)
    .bind(&now)
    .execute(db.pool())
    .await?;

    let sql = format!("{SELECT_RUN} WHERE id = ?");

    Ok(sqlx::query_as::<_, ScanRunRow>(&sql)
        .bind(&id)
        .fetch_one(db.pool())
        .await?)
}

pub async fn record_progress(
    db: &Db,
    run_id: &str,
    seen: i64,
    indexed: i64,
    failed: i64,
) -> Result<(), DbError> {
    sqlx::query(
        "UPDATE scan_runs SET files_seen = ?, files_indexed = ?, files_failed = ? WHERE id = ?",
    )
    .bind(seen)
    .bind(indexed)
    .bind(failed)
    .bind(run_id)
    .execute(db.pool())
    .await?;

    Ok(())
}

/// One row per file the scan could not index. A scan never aborts on one bad
/// file (design rule 1), so this is the only place those failures survive.
pub async fn record_issue(
    db: &Db,
    run_id: &str,
    path: &str,
    reason: &str,
    detail: Option<&str>,
) -> Result<(), DbError> {
    sqlx::query(
        "INSERT INTO scan_issues (id, scan_run_id, path, reason, detail, occurred_at)
         VALUES (?, ?, ?, ?, ?, ?)",
    )
    .bind(uuid::Uuid::new_v4().to_string())
    .bind(run_id)
    .bind(path)
    .bind(reason)
    .bind(detail)
    .bind(Utc::now().to_rfc3339())
    .execute(db.pool())
    .await?;

    Ok(())
}

pub async fn finish(db: &Db, run_id: &str) -> Result<(), DbError> {
    sqlx::query("UPDATE scan_runs SET state = 'completed', finished_at = ? WHERE id = ?")
        .bind(Utc::now().to_rfc3339())
        .bind(run_id)
        .execute(db.pool())
        .await?;

    Ok(())
}

pub async fn fail(db: &Db, run_id: &str, error: &str) -> Result<(), DbError> {
    sqlx::query("UPDATE scan_runs SET state = 'failed', finished_at = ?, error = ? WHERE id = ?")
        .bind(Utc::now().to_rfc3339())
        .bind(error)
        .bind(run_id)
        .execute(db.pool())
        .await?;

    Ok(())
}

pub async fn latest(db: &Db, library_path_id: &str) -> Result<Option<ScanRunRow>, DbError> {
    let sql = format!("{SELECT_RUN} WHERE library_path_id = ? ORDER BY started_at DESC LIMIT 1");

    Ok(sqlx::query_as::<_, ScanRunRow>(&sql)
        .bind(library_path_id)
        .fetch_optional(db.pool())
        .await?)
}

pub async fn issues(db: &Db, run_id: &str) -> Result<Vec<ScanIssueRow>, DbError> {
    Ok(sqlx::query_as::<_, ScanIssueRow>(
        "SELECT id, scan_run_id, path, reason, detail, occurred_at
         FROM scan_issues WHERE scan_run_id = ? ORDER BY occurred_at, path",
    )
    .bind(run_id)
    .fetch_all(db.pool())
    .await?)
}

/// Closes out runs left in `running` by a process that died. Called once at
/// boot, before any new scan starts, so the admin UI never shows a scan that
/// has not moved since last week as still in progress.
pub async fn abandon_running(db: &Db) -> Result<u64, DbError> {
    let affected = sqlx::query(
        "UPDATE scan_runs
         SET state = 'failed', finished_at = ?, error = 'the server stopped during this scan'
         WHERE state = 'running'",
    )
    .bind(Utc::now().to_rfc3339())
    .execute(db.pool())
    .await?
    .rows_affected();

    Ok(affected)
}

#[cfg(test)]
mod tests {
    use super::{
        abandon_running, fail, finish, issues, latest, record_issue, record_progress, start,
    };
    use crate::library_paths::sync_from_config;
    use crate::pool::connect_temp;
    use crate::Db;

    async fn library(db: &Db) -> String {
        sync_from_config(db, &[("/media".to_string(), "mixed".to_string())])
            .await
            .unwrap()[0]
            .id
            .clone()
    }

    #[tokio::test]
    async fn a_started_run_is_running() {
        let (db, _g) = connect_temp().await.unwrap();
        let lp = library(&db).await;

        let run = start(&db, &lp).await.unwrap();

        assert_eq!(run.state, "running");
        assert!(run.finished_at.is_none());
        assert_eq!(latest(&db, &lp).await.unwrap().unwrap().id, run.id);
    }

    #[tokio::test]
    async fn progress_is_recorded() {
        let (db, _g) = connect_temp().await.unwrap();
        let lp = library(&db).await;
        let run = start(&db, &lp).await.unwrap();

        record_progress(&db, &run.id, 100, 96, 4).await.unwrap();

        let latest = latest(&db, &lp).await.unwrap().unwrap();

        assert_eq!(latest.files_seen, 100);
        assert_eq!(latest.files_indexed, 96);
        assert_eq!(latest.files_failed, 4);
    }

    #[tokio::test]
    async fn finishing_marks_the_run_complete() {
        let (db, _g) = connect_temp().await.unwrap();
        let lp = library(&db).await;
        let run = start(&db, &lp).await.unwrap();

        finish(&db, &run.id).await.unwrap();

        let latest = latest(&db, &lp).await.unwrap().unwrap();

        assert_eq!(latest.state, "completed");
        assert!(latest.finished_at.is_some());
        assert!(latest.error.is_none());
    }

    #[tokio::test]
    async fn failing_records_the_reason() {
        let (db, _g) = connect_temp().await.unwrap();
        let lp = library(&db).await;
        let run = start(&db, &lp).await.unwrap();

        fail(&db, &run.id, "the library path is not readable")
            .await
            .unwrap();

        let latest = latest(&db, &lp).await.unwrap().unwrap();

        assert_eq!(latest.state, "failed");
        assert_eq!(
            latest.error.as_deref(),
            Some("the library path is not readable")
        );
        assert!(latest.finished_at.is_some());
    }

    #[tokio::test]
    async fn issues_are_recorded_against_their_run() {
        let (db, _g) = connect_temp().await.unwrap();
        let lp = library(&db).await;
        let run = start(&db, &lp).await.unwrap();

        record_issue(&db, &run.id, "/media/odd.mkv", "unparsed", None)
            .await
            .unwrap();
        record_issue(
            &db,
            &run.id,
            "/media/broken.mkv",
            "probe_failed",
            Some("moov atom not found"),
        )
        .await
        .unwrap();

        let recorded = issues(&db, &run.id).await.unwrap();

        assert_eq!(recorded.len(), 2);
        assert!(recorded.iter().any(|i| i.reason == "unparsed"));
        assert!(recorded
            .iter()
            .any(|i| i.detail.as_deref() == Some("moov atom not found")));
    }

    #[tokio::test]
    async fn latest_returns_the_most_recent_run() {
        let (db, _g) = connect_temp().await.unwrap();
        let lp = library(&db).await;

        let first = start(&db, &lp).await.unwrap();
        finish(&db, &first.id).await.unwrap();
        let second = start(&db, &lp).await.unwrap();

        assert_eq!(latest(&db, &lp).await.unwrap().unwrap().id, second.id);
    }

    #[tokio::test]
    async fn a_run_left_running_by_a_crash_is_abandoned_at_boot() {
        let (db, _g) = connect_temp().await.unwrap();
        let lp = library(&db).await;
        start(&db, &lp).await.unwrap();

        let abandoned = abandon_running(&db).await.unwrap();

        assert_eq!(abandoned, 1);

        let latest = latest(&db, &lp).await.unwrap().unwrap();
        assert_eq!(latest.state, "failed");
        assert!(latest.error.is_some());
    }
}
