//! Release blacklist. Rust port of
//! `lib/mydia/downloads/release_blacklist.ex` +
//! `lib/mydia/downloads/blacklists.ex`.
//!
//! ## Match semantics
//!
//! The blacklist key is `(indexer, guid)` — both string-equality
//! comparisons, with `indexer` normalized to lowercase trimmed text.
//! There is **no substring matching** on titles: a row for
//! `"Indexer A" / "abc-123"` blocks exactly that pair, not any
//! release whose title happens to contain `"abc-123"`. The plan
//! flags this as an edge case worth covering in tests; see the
//! `substring_titles_not_blocked` test below.
//!
//! ## Storage abstraction
//!
//! Phoenix persists rows in `SQLite` via Ecto. This crate ships the
//! [`Blacklist`] facade and an in-memory [`MemoryStore`] used by
//! tests and dev; the real DB-backed store lands when U17 wires
//! `sqlx` writes. Both implement the [`BlacklistStore`] trait so
//! the orchestrator code is store-agnostic.

use std::sync::Arc;

use chrono::{DateTime, Duration as ChronoDuration, Utc};
use tokio::sync::RwLock;

use mydia_rs_db::types::{DateTimeMicros, UuidText};
use mydia_rs_entities::release_blacklist;
use sea_orm::entity::prelude::*;
use sea_orm::sea_query::{Expr, ExprTrait, SimpleExpr, Value};
use sea_orm::{DbBackend, PaginatorTrait, QueryOrder};

/// One blacklist row. Carries the same fields as Phoenix's
/// `Mydia.Downloads.ReleaseBlacklist` schema.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BlacklistEntry {
    pub indexer: String,
    pub guid: String,
    pub title: String,
    pub failure_reason: String,
    /// `None` means "block forever"; `Some(_)` is the timestamp at
    /// which the row should be considered expired.
    pub expires_at: Option<DateTime<Utc>>,
    pub inserted_at: DateTime<Utc>,
}

impl BlacklistEntry {
    /// `true` when `now` falls before the expiry (or expiry is
    /// `None`).
    #[must_use]
    pub fn is_active(&self, now: DateTime<Utc>) -> bool {
        match self.expires_at {
            None => true,
            Some(exp) => exp > now,
        }
    }
}

/// Storage backend for [`Blacklist`]. Implementors are responsible
/// for persistence; the trait is async to leave room for `sqlx`-
/// backed implementations later.
#[async_trait::async_trait]
pub trait BlacklistStore: Send + Sync + 'static {
    /// Insert or overwrite the row keyed by `(indexer, guid)`.
    async fn upsert(&self, entry: BlacklistEntry);

    /// True when an unexpired row for `(indexer, guid)` exists.
    async fn is_blacklisted(&self, indexer: &str, guid: &str, now: DateTime<Utc>) -> bool;

    /// All currently active rows (used by the admin `LiveView` /
    /// REST surface).
    async fn list_active(&self, now: DateTime<Utc>) -> Vec<BlacklistEntry>;

    /// Delete by `(indexer, guid)`. Returns whether a row was
    /// removed.
    async fn remove(&self, indexer: &str, guid: &str) -> bool;

    /// Sweep expired rows. Returns the number removed.
    async fn cleanup_expired(&self, now: DateTime<Utc>) -> usize;
}

/// Default in-memory store backed by a `Vec` under an `RwLock`. The
/// blacklist is small (admin-curated; rarely exceeds a few hundred
/// rows) so a linear scan beats a more elaborate index here.
#[derive(Default)]
pub struct MemoryStore {
    rows: RwLock<Vec<BlacklistEntry>>,
}

impl MemoryStore {
    /// Fresh empty store.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }
}

#[async_trait::async_trait]
impl BlacklistStore for MemoryStore {
    async fn upsert(&self, entry: BlacklistEntry) {
        let mut rows = self.rows.write().await;
        if let Some(existing) = rows
            .iter_mut()
            .find(|r| r.indexer == entry.indexer && r.guid == entry.guid)
        {
            *existing = entry;
        } else {
            rows.push(entry);
        }
    }

    async fn is_blacklisted(&self, indexer: &str, guid: &str, now: DateTime<Utc>) -> bool {
        let rows = self.rows.read().await;
        let normalized = normalize_indexer(indexer);
        rows.iter()
            .any(|row| row.indexer == normalized && row.guid == guid && row.is_active(now))
    }

    async fn list_active(&self, now: DateTime<Utc>) -> Vec<BlacklistEntry> {
        let rows = self.rows.read().await;
        rows.iter().filter(|r| r.is_active(now)).cloned().collect()
    }

    async fn remove(&self, indexer: &str, guid: &str) -> bool {
        let mut rows = self.rows.write().await;
        let before = rows.len();
        let normalized = normalize_indexer(indexer);
        rows.retain(|r| !(r.indexer == normalized && r.guid == guid));
        before != rows.len()
    }

    async fn cleanup_expired(&self, now: DateTime<Utc>) -> usize {
        let mut rows = self.rows.write().await;
        let before = rows.len();
        rows.retain(|r| r.is_active(now));
        before - rows.len()
    }
}

/// Database-backed blacklist store using `SeaORM` and the `release_blacklist`
/// entity. Uniform across both database backends (`SQLite`, `Postgres`).
pub struct SeaOrmStore {
    db: DatabaseConnection,
}

impl SeaOrmStore {
    /// Create a new `SeaOrmStore` backed by the given DB connection.
    #[must_use]
    pub fn new(db: DatabaseConnection) -> Self {
        Self { db }
    }
}

#[async_trait::async_trait]
impl BlacklistStore for SeaOrmStore {
    async fn upsert(&self, entry: BlacklistEntry) {
        let normalized = normalize_indexer(&entry.indexer);
        let backend = self.db.get_database_backend();

        // 1. Check if the row already exists
        let existing = release_blacklist::Entity::find()
            .filter(release_blacklist::Column::Indexer.eq(&normalized))
            .filter(release_blacklist::Column::Guid.eq(&entry.guid))
            .one(&self.db)
            .await;

        let expires = entry.expires_at.map(DateTimeMicros::from);
        let inserted = DateTimeMicros::from(entry.inserted_at);

        if let Ok(Some(row)) = existing {
            // Update the existing row
            let mut update_query = release_blacklist::Entity::update_many()
                .col_expr(release_blacklist::Column::Title, Expr::value(&entry.title))
                .col_expr(
                    release_blacklist::Column::FailureReason,
                    Expr::value(&entry.failure_reason),
                )
                .col_expr(
                    release_blacklist::Column::InsertedAt,
                    inserted.into_simple_expr(backend),
                );

            let expires_expr = match expires {
                Some(exp) => exp.into_simple_expr(backend),
                None => match backend {
                    DbBackend::Sqlite => SimpleExpr::Value(Value::String(None)),
                    DbBackend::Postgres => {
                        Expr::cust_with_values("$1::timestamptz", vec![Value::String(None)])
                    }
                    _ => unreachable!("mydia-rs is dual-engine SQLite/Postgres only"),
                },
            };

            update_query =
                update_query.col_expr(release_blacklist::Column::ExpiresAt, expires_expr);

            let _ = update_query
                .filter(
                    Expr::col(release_blacklist::Column::Id).eq(row.id.into_simple_expr(backend)),
                )
                .exec(&self.db)
                .await;
        } else {
            // Insert a new row
            let id = UuidText::new_v4();
            let am = release_blacklist::ActiveModel {
                id: sea_orm::Set(id),
                indexer: sea_orm::Set(normalized),
                guid: sea_orm::Set(entry.guid.clone()),
                title: sea_orm::Set(entry.title.clone()),
                failure_reason: sea_orm::Set(entry.failure_reason.clone()),
                expires_at: sea_orm::Set(expires),
                inserted_at: sea_orm::Set(inserted),
            };

            let _ = mydia_rs_db::insert_active_model(am, &self.db).await;
        }
    }

    async fn is_blacklisted(&self, indexer: &str, guid: &str, now: DateTime<Utc>) -> bool {
        let normalized = normalize_indexer(indexer);
        let now_db = DateTimeMicros::from(now);
        let backend = self.db.get_database_backend();

        let count = release_blacklist::Entity::find()
            .filter(release_blacklist::Column::Indexer.eq(&normalized))
            .filter(release_blacklist::Column::Guid.eq(guid))
            .filter(
                release_blacklist::Column::ExpiresAt
                    .is_null()
                    .or(Expr::col(release_blacklist::Column::ExpiresAt)
                        .gt(now_db.into_simple_expr(backend))),
            )
            .count(&self.db)
            .await
            .unwrap_or(0);

        count > 0
    }

    async fn list_active(&self, now: DateTime<Utc>) -> Vec<BlacklistEntry> {
        let now_db = DateTimeMicros::from(now);
        let backend = self.db.get_database_backend();

        let rows = release_blacklist::Entity::find()
            .filter(
                release_blacklist::Column::ExpiresAt
                    .is_null()
                    .or(Expr::col(release_blacklist::Column::ExpiresAt)
                        .gt(now_db.into_simple_expr(backend))),
            )
            .order_by_asc(release_blacklist::Column::ExpiresAt)
            .all(&self.db)
            .await
            .unwrap_or_default();

        rows.into_iter()
            .map(|r| BlacklistEntry {
                indexer: r.indexer,
                guid: r.guid,
                title: r.title,
                failure_reason: r.failure_reason,
                expires_at: r.expires_at.map(|d| d.0),
                inserted_at: r.inserted_at.0,
            })
            .collect()
    }

    async fn remove(&self, indexer: &str, guid: &str) -> bool {
        let normalized = normalize_indexer(indexer);
        let res = release_blacklist::Entity::delete_many()
            .filter(release_blacklist::Column::Indexer.eq(&normalized))
            .filter(release_blacklist::Column::Guid.eq(guid))
            .exec(&self.db)
            .await;

        match res {
            Ok(delete_result) => delete_result.rows_affected > 0,
            Err(_) => false,
        }
    }

    async fn cleanup_expired(&self, now: DateTime<Utc>) -> usize {
        let now_db = DateTimeMicros::from(now);
        let backend = self.db.get_database_backend();

        let res = release_blacklist::Entity::delete_many()
            .filter(release_blacklist::Column::ExpiresAt.is_not_null())
            .filter(
                Expr::col(release_blacklist::Column::ExpiresAt)
                    .lt(now_db.into_simple_expr(backend)),
            )
            .exec(&self.db)
            .await;

        match res {
            Ok(delete_result) => delete_result.rows_affected as usize,
            Err(_) => 0,
        }
    }
}

/// Top-level blacklist facade. Wraps a [`BlacklistStore`] in an
/// `Arc` so multiple call sites (orchestrator, REST handlers, admin
/// `LiveView`) can share one instance.
#[derive(Clone)]
pub struct Blacklist {
    store: Arc<dyn BlacklistStore>,
    default_ttl: ChronoDuration,
}

impl Blacklist {
    /// Build with the given store + default TTL. Phoenix defaults
    /// to 30 days when `release_blacklist_default_ttl_days` is unset.
    #[must_use]
    pub fn new(store: Arc<dyn BlacklistStore>, default_ttl: ChronoDuration) -> Self {
        Self { store, default_ttl }
    }

    /// Convenience constructor with the default 30-day TTL and a
    /// fresh [`MemoryStore`].
    #[must_use]
    pub fn in_memory() -> Self {
        Self::new(Arc::new(MemoryStore::new()), ChronoDuration::days(30))
    }

    /// Add a row. `expires_at = None` means "block forever"; otherwise
    /// the TTL is added to `now`.
    pub async fn add(
        &self,
        indexer: impl Into<String>,
        guid: impl Into<String>,
        title: impl Into<String>,
        failure_reason: impl Into<String>,
        expires_at: Option<DateTime<Utc>>,
    ) {
        let now = Utc::now();
        let entry = BlacklistEntry {
            indexer: normalize_indexer(&indexer.into()),
            guid: guid.into(),
            title: title.into(),
            failure_reason: failure_reason.into(),
            expires_at: expires_at.or_else(|| Some(now + self.default_ttl)),
            inserted_at: now,
        };
        self.store.upsert(entry).await;
    }

    /// Add with explicit forever-block semantics. Mirrors Phoenix's
    /// `block_forever` admin action.
    pub async fn add_forever(
        &self,
        indexer: impl Into<String>,
        guid: impl Into<String>,
        title: impl Into<String>,
        failure_reason: impl Into<String>,
    ) {
        let entry = BlacklistEntry {
            indexer: normalize_indexer(&indexer.into()),
            guid: guid.into(),
            title: title.into(),
            failure_reason: failure_reason.into(),
            expires_at: None,
            inserted_at: Utc::now(),
        };
        self.store.upsert(entry).await;
    }

    /// True when `(indexer, guid)` has an unexpired row.
    pub async fn is_blacklisted(&self, indexer: &str, guid: &str) -> bool {
        self.store.is_blacklisted(indexer, guid, Utc::now()).await
    }

    /// List all currently active rows.
    pub async fn list_active(&self) -> Vec<BlacklistEntry> {
        self.store.list_active(Utc::now()).await
    }

    /// Drop a row.
    pub async fn remove(&self, indexer: &str, guid: &str) -> bool {
        self.store.remove(indexer, guid).await
    }

    /// Sweep expired rows.
    pub async fn cleanup_expired(&self) -> usize {
        self.store.cleanup_expired(Utc::now()).await
    }
}

/// Normalize an indexer name for storage / lookup. Mirrors
/// Phoenix's `ReleaseBlacklist.normalize_indexer/1` (lowercase +
/// trim).
fn normalize_indexer(raw: &str) -> String {
    raw.trim().to_lowercase()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn upsert_and_lookup_round_trip() {
        let bl = Blacklist::in_memory();
        bl.add("Indexer", "guid-1", "Some.Release", "stalled", None)
            .await;
        assert!(bl.is_blacklisted("indexer", "guid-1").await);
        assert!(bl.is_blacklisted("INDEXER", "guid-1").await);
        assert!(!bl.is_blacklisted("indexer", "guid-2").await);
    }

    #[tokio::test]
    async fn substring_titles_not_blocked() {
        // The Edge case noted in the plan: blacklist match is exact
        // (no false positives on title substrings).
        let bl = Blacklist::in_memory();
        bl.add("indexer-a", "abc-123", "Some.Release", "stalled", None)
            .await;
        // A different guid that contains the blacklisted guid as a
        // substring must NOT be blocked.
        assert!(!bl.is_blacklisted("indexer-a", "x-abc-123-y").await);
        // Mismatched indexer also not blocked.
        assert!(!bl.is_blacklisted("indexer-b", "abc-123").await);
    }

    #[tokio::test]
    async fn expired_rows_are_invisible() {
        let store: Arc<MemoryStore> = Arc::new(MemoryStore::new());
        store
            .upsert(BlacklistEntry {
                indexer: "indexer-a".into(),
                guid: "expired".into(),
                title: "old".into(),
                failure_reason: "stalled".into(),
                expires_at: Some(Utc::now() - ChronoDuration::hours(1)),
                inserted_at: Utc::now() - ChronoDuration::days(1),
            })
            .await;
        assert!(
            !store
                .is_blacklisted("indexer-a", "expired", Utc::now())
                .await
        );
        let removed = store.cleanup_expired(Utc::now()).await;
        assert_eq!(removed, 1);
        assert_eq!(store.list_active(Utc::now()).await.len(), 0);
    }

    #[tokio::test]
    async fn remove_returns_true_only_when_row_existed() {
        let bl = Blacklist::in_memory();
        bl.add("indexer", "guid", "title", "reason", None).await;
        assert!(bl.remove("indexer", "guid").await);
        assert!(!bl.remove("indexer", "guid").await);
    }

    #[tokio::test]
    async fn add_forever_persists_null_expires() {
        let bl = Blacklist::in_memory();
        bl.add_forever("indexer", "g", "t", "r").await;
        let rows = bl.list_active().await;
        assert_eq!(rows.len(), 1);
        assert!(rows[0].expires_at.is_none());
    }
}
