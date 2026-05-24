//! Shared test helpers for the web crate.
//!
//! Each test opens a fresh in-memory SQLite `DatabaseConnection` and
//! applies the schema it needs. The U14 SeaORM conversion replaced the
//! legacy `Db` enum + raw sqlx with `DatabaseConnection`; the U17 sweep
//! that followed removed the remaining raw-sqlx seeders, so test fixture
//! writes now route through `db.execute_unprepared(...)` directly. The
//! production server fns under test take `&DatabaseConnection` directly,
//! so the test threads the SeaORM connection straight through.
//!
//! FK enforcement is disabled because most fixture schemas reference
//! sibling tables (`users`, `quality_profiles`, ...) that the tests
//! deliberately don't create.

#![allow(dead_code)]
#![cfg(feature = "server")]

use sea_orm::{ConnectionTrait, Database, DatabaseConnection};

/// Build a fresh in-memory SQLite `DatabaseConnection` with FK
/// enforcement disabled. Apply schema DDL via [`apply_sql`] or
/// `db.execute_unprepared(...)` after this returns.
pub async fn fresh_db() -> DatabaseConnection {
    let db = Database::connect("sqlite::memory:")
        .await
        .expect("connect in-memory sqlite");
    db.execute_unprepared("PRAGMA foreign_keys = OFF")
        .await
        .expect("disable fk");
    db
}

/// Apply a multi-statement SQL string to the connection. Splits on
/// `;`, trims, skips empty statements. Designed for the hand-written
/// fixture DDL each test file declares.
pub async fn apply_sql(db: &DatabaseConnection, sql: &str) {
    for stmt in sql.split(';') {
        let trimmed = stmt.trim();
        if !trimmed.is_empty() {
            db.execute_unprepared(trimmed)
                .await
                .expect("apply DDL statement");
        }
    }
}
