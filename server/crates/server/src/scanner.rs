//! The background scan.
//!
//! A supervised task rather than a job queue: this slice has one job kind, and
//! apalis earns its place in Slice 5 where transcode-to-file needs
//! cancellation and retries. Durable progress already lives in scan_runs, so
//! introducing a queue later does not change what the API reads.

use std::time::Duration;

use mydia_config::LibrarySettings;
use mydia_db::Db;

/// Runs one pass over every monitored library path.
///
/// Returns nothing: a scan failure is an operational event, recorded in
/// scan_runs and logged, not something a caller can usefully act on.
pub async fn run_once(db: &Db) {
    match mydia_library::scan::scan_all(db).await {
        Ok(outcomes) => {
            for (library_path_id, outcome) in outcomes {
                tracing::info!(
                    library_path_id,
                    seen = outcome.files_seen,
                    indexed = outcome.files_indexed,
                    failed = outcome.files_failed,
                    "scan finished"
                );
            }
        }
        Err(error) => {
            tracing::error!(%error, "the scan could not run");
        }
    }
}

/// Spawns the scan loop. A panic inside one pass is caught here so it cannot
/// take the process down (design rule 4), and the loop continues on its next
/// tick.
pub fn spawn(db: Db, settings: LibrarySettings) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        if settings.scan_on_start {
            supervised(&db).await;
        }

        if settings.scan_interval_seconds == 0 {
            tracing::info!("periodic scanning is disabled");
            return;
        }

        let mut ticker = tokio::time::interval(Duration::from_secs(settings.scan_interval_seconds));
        // The first tick fires immediately, and the start-up scan has already
        // covered it.
        ticker.tick().await;

        loop {
            ticker.tick().await;
            supervised(&db).await;
        }
    })
}

async fn supervised(db: &Db) {
    let db = db.clone();

    // AssertUnwindSafe is sound here: the only state crossing the boundary is
    // a connection pool, and a poisoned scan leaves rows, not invariants.
    let result = futures_util::FutureExt::catch_unwind(std::panic::AssertUnwindSafe(async move {
        run_once(&db).await;
    }))
    .await;

    if result.is_err() {
        tracing::error!("a scan panicked; the next scheduled scan will run as normal");
    }
}

#[cfg(test)]
mod tests {
    use super::run_once;
    use mydia_db::pool::connect_temp;

    #[tokio::test]
    async fn a_scan_with_no_library_paths_does_nothing_and_does_not_panic() {
        let (db, _g) = connect_temp().await.unwrap();

        run_once(&db).await;

        let runs: i64 = sqlx::query_scalar("SELECT count(*) FROM scan_runs")
            .fetch_one(db.pool())
            .await
            .unwrap();

        assert_eq!(runs, 0);
    }

    #[tokio::test]
    async fn a_library_path_that_does_not_exist_is_logged_not_fatal() {
        let (db, _g) = connect_temp().await.unwrap();

        mydia_db::library_paths::sync_from_config(
            &db,
            &[("/definitely/not/here".to_string(), "movies".to_string())],
        )
        .await
        .unwrap();

        // The point is that this returns rather than propagating.
        run_once(&db).await;

        let run = mydia_db::scan_runs::latest(
            &db,
            &mydia_db::library_paths::list(&db).await.unwrap()[0].id,
        )
        .await
        .unwrap()
        .unwrap();

        assert_eq!(run.state, "failed");
    }
}
