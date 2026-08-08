//! Reads the database overlay layer, the highest-precedence configuration
//! source. Rows are written by the admin UI when an operator edits a setting.

use mydia_db::{Db, DbError};

pub async fn read_overlay(db: &Db) -> Result<Vec<(String, String)>, DbError> {
    let rows = sqlx::query_as("SELECT key, value FROM settings ORDER BY key")
        .fetch_all(db.pool())
        .await?;

    Ok(rows)
}
