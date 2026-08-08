//! Reads the database overlay layer, the highest-precedence configuration
//! source. Rows are written by the admin UI when an operator edits a setting.

use mydia_db::{Db, DbError};

pub async fn read_overlay(db: &Db) -> Result<Vec<(String, String)>, DbError> {
    let rows = sqlx::query_as("SELECT key, value FROM settings ORDER BY key")
        .fetch_all(db.pool())
        .await?;

    Ok(rows)
}

/// Writes a single overlay row, creating it if it does not exist yet.
///
/// Used at first boot to persist a generated `secret_key_base` so it survives
/// restarts; the admin UI will reuse this for operator-edited settings later.
pub async fn write_setting(db: &Db, key: &str, value: &str) -> Result<(), DbError> {
    let now = chrono::Utc::now().to_rfc3339();

    sqlx::query(
        "INSERT INTO settings (key, value, updated_at) VALUES (?, ?, ?)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at",
    )
    .bind(key)
    .bind(value)
    .bind(now)
    .execute(db.pool())
    .await?;

    Ok(())
}

/// Ensures a JWT signing key exists, generating and persisting one on first
/// boot if no configuration layer supplied it. `current` is whatever the
/// regular layered load produced for `secret_key_base` (possibly empty).
pub async fn ensure_secret_key_base(db: &Db, current: &str) -> Result<String, DbError> {
    if !current.is_empty() {
        return Ok(current.to_string());
    }

    let generated = crate::generate_secret_key_base();
    write_setting(db, "secret_key_base", &generated).await?;

    Ok(generated)
}

#[cfg(test)]
mod tests {
    use super::{ensure_secret_key_base, read_overlay};
    use mydia_db::pool::connect_temp;

    #[tokio::test]
    async fn a_missing_secret_key_base_is_generated_and_persisted() {
        let (db, _guard) = connect_temp().await.unwrap();

        let generated = ensure_secret_key_base(&db, "").await.unwrap();
        assert!(!generated.is_empty());

        let overlay = read_overlay(&db).await.unwrap();
        assert!(overlay.contains(&("secret_key_base".to_string(), generated)));
    }

    #[tokio::test]
    async fn an_existing_secret_key_base_is_left_untouched() {
        let (db, _guard) = connect_temp().await.unwrap();

        let result = ensure_secret_key_base(&db, "already-configured")
            .await
            .unwrap();

        assert_eq!(result, "already-configured");

        let overlay = read_overlay(&db).await.unwrap();
        assert!(overlay.is_empty(), "should not write when already set");
    }
}
