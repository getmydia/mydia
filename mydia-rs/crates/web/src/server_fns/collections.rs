//! Collections page server functions (U26).
//!
//! Read-only port of `MydiaWeb.CollectionLive.Index` + `Show`. The
//! Phoenix surface carries a smart-rules engine, manual ordering, and
//! sharing affordances; the Rust port establishes the read path —
//! listing collections accessible to the session user, fetching one
//! by id with item counts and poster previews, and walking the
//! `collection_items` join to render a card grid.
//!
//! Smart-collection materialization (`SmartRules.execute_query!`) is
//! out of scope; the show page surfaces smart collections with their
//! stored title, type badge, and an "empty / not yet implemented"
//! body. Manual collections render their member media items via the
//! standard `MediaCard` grid.

use dioxus::fullstack::ServerFnError;
use dioxus::prelude::*;
use serde::{Deserialize, Serialize};

/// Item count surfaced in the index card and the show-page header.
///
/// For manual collections this is `COUNT(*)` over `collection_items`;
/// for smart collections it's `0` (placeholder — Phoenix runs the
/// rules engine to count matches, which the Rust port doesn't carry).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CollectionListItem {
    pub id: String,
    pub name: String,
    pub description: Option<String>,
    /// `"manual"` or `"smart"`. Unknown values pass through verbatim so
    /// the front-end can still render an "unknown type" badge if the
    /// schema grows.
    pub kind: String,
    /// `"private"` or `"shared"`.
    pub visibility: String,
    pub is_system: bool,
    pub item_count: i64,
    /// Up to four TMDB-relative poster paths from the first members,
    /// rendered as a collage on the card. Smart collections return an
    /// empty list (engine not ported).
    pub poster_paths: Vec<String>,
    /// True if the session user owns the collection. The card surfaces
    /// edit affordances only for owned rows; the index page hides them
    /// for everyone-else's shared rows.
    pub owned: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
pub struct CollectionListQuery {
    /// Case-insensitive substring search against `name`. Empty means no
    /// filter. Mirrors the Phoenix in-page search box.
    #[serde(default)]
    pub search: String,
    /// Optional kind filter — `Some("manual")` / `Some("smart")` /
    /// `None` (all). Strings rather than enum so unknown values can be
    /// passed through during schema evolution without breaking the
    /// wire.
    #[serde(default)]
    pub kind: Option<String>,
    #[serde(default)]
    pub visibility: Option<String>,
}

#[post("/api/collections/list")]
pub async fn list_collections(
    query: CollectionListQuery,
) -> Result<Vec<CollectionListItem>, ServerFnError> {
    server::list_collections(query).await
}

/// Detail view for `/collections/:id`. Mirrors the headline fields
/// `CollectionLive.Show` surfaces before its body iterates items.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CollectionDetail {
    pub id: String,
    pub name: String,
    pub description: Option<String>,
    pub kind: String,
    pub visibility: String,
    pub is_system: bool,
    pub item_count: i64,
    pub owned: bool,
}

#[post("/api/collections/detail")]
pub async fn get_collection_detail(id: String) -> Result<CollectionDetail, ServerFnError> {
    server::get_collection_detail(&id).await
}

/// One member item in a collection's grid. Lighter than
/// [`crate::server_fns::media::MediaListItem`] because the show page
/// doesn't need the monitored / `has_files` badges — clicking through to
/// `/media/:id` surfaces those.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CollectionMember {
    pub id: String,
    pub title: String,
    pub year: Option<i32>,
    pub kind: String,
    pub poster_path: Option<String>,
}

#[post("/api/collections/items")]
pub async fn list_collection_items(id: String) -> Result<Vec<CollectionMember>, ServerFnError> {
    server::list_collection_items(&id).await
}

#[cfg(feature = "server")]
pub mod server {
    //! Server-only SQL helpers. The inner functions are `pub` so the
    //! integration tests can drive them against a real fixture pool
    //! without the full `FullstackContext` + session plumbing.

    use super::{CollectionDetail, CollectionListItem, CollectionListQuery, CollectionMember};
    use crate::server_fns::auth::require_session_user_id;
    use crate::server_state::WebState;
    use dioxus::fullstack::{FullstackContext, ServerFnError};
    use mydia_rs_db::Db;

    fn state() -> Result<WebState, ServerFnError> {
        let ctx = FullstackContext::current()
            .ok_or_else(|| ServerFnError::new("no fullstack context"))?;
        ctx.extension::<WebState>()
            .ok_or_else(|| ServerFnError::new("WebState extension missing"))
    }

    pub(super) async fn list_collections(
        query: CollectionListQuery,
    ) -> Result<Vec<CollectionListItem>, ServerFnError> {
        let user_id = require_session_user_id().await?;
        let st = state()?;
        fetch_collections(&st.db, &user_id, &query).await
    }

    pub(super) async fn get_collection_detail(id: &str) -> Result<CollectionDetail, ServerFnError> {
        let user_id = require_session_user_id().await?;
        let st = state()?;
        fetch_collection_detail(&st.db, &user_id, id).await
    }

    pub(super) async fn list_collection_items(
        id: &str,
    ) -> Result<Vec<CollectionMember>, ServerFnError> {
        let user_id = require_session_user_id().await?;
        let st = state()?;
        fetch_collection_items(&st.db, &user_id, id).await
    }

    /// Tuple shape for the base collection row. Pulled out of the
    /// fetch helpers so the test surface can drive it with the same
    /// type — sqlx `FromRow` on the typed `Collection` struct would
    /// require porting the schema into `crates/models`, which is U26
    /// out-of-scope.
    type CollectionRow = (
        String,         // id
        String,         // name
        Option<String>, // description
        String,         // type (manual/smart)
        String,         // visibility
        bool,           // is_system
        String,         // user_id
    );

    /// Phoenix `Collections.list_collections(user, include_shared: true)` —
    /// returns the user's own collections + every `shared` collection,
    /// ordered by position then name. We don't sort by position here
    /// because the Rust port treats position as Phoenix-managed state
    /// (the operator can still re-order via the Phoenix UI during the
    /// cutover window; future Rust UI work covers reordering).
    pub async fn fetch_collections(
        db: &Db,
        user_id: &str,
        query: &CollectionListQuery,
    ) -> Result<Vec<CollectionListItem>, ServerFnError> {
        let search = if query.search.trim().is_empty() {
            None
        } else {
            Some(query.search.trim().to_lowercase())
        };
        let kind = query
            .kind
            .as_deref()
            .filter(|k| matches!(*k, "manual" | "smart"));
        let visibility = query
            .visibility
            .as_deref()
            .filter(|v| matches!(*v, "private" | "shared"));

        let rows = fetch_collection_rows(db, user_id, search.as_deref(), kind, visibility).await?;

        let mut items = Vec::with_capacity(rows.len());
        for row in rows {
            let (id, name, description, kind, visibility, is_system, row_user_id) = row;
            let item_count = if kind == "manual" {
                count_manual_items(db, &id).await?
            } else {
                0
            };
            let poster_paths = if kind == "manual" {
                manual_poster_paths(db, &id, 4).await?
            } else {
                Vec::new()
            };
            items.push(CollectionListItem {
                id,
                name,
                description,
                kind,
                visibility,
                is_system,
                item_count,
                poster_paths,
                owned: row_user_id == user_id,
            });
        }
        Ok(items)
    }

    pub async fn fetch_collection_detail(
        db: &Db,
        user_id: &str,
        id: &str,
    ) -> Result<CollectionDetail, ServerFnError> {
        let row = fetch_collection_row(db, user_id, id).await?;
        let (id, name, description, kind, visibility, is_system, row_user_id) = row;
        let item_count = if kind == "manual" {
            count_manual_items(db, &id).await?
        } else {
            0
        };
        Ok(CollectionDetail {
            id,
            name,
            description,
            kind,
            visibility,
            is_system,
            item_count,
            owned: row_user_id == user_id,
        })
    }

    pub async fn fetch_collection_items(
        db: &Db,
        user_id: &str,
        id: &str,
    ) -> Result<Vec<CollectionMember>, ServerFnError> {
        // Access check — same predicate as fetch_collection_detail.
        let (_, _, _, kind, _, _, _) = fetch_collection_row(db, user_id, id).await?;
        if kind != "manual" {
            // Smart collections: the rules engine isn't ported. Show
            // page renders an "engine not available" placeholder.
            return Ok(Vec::new());
        }
        fetch_manual_members(db, id).await
    }

    async fn fetch_collection_rows(
        db: &Db,
        user_id: &str,
        search: Option<&str>,
        kind: Option<&str>,
        visibility: Option<&str>,
    ) -> Result<Vec<CollectionRow>, ServerFnError> {
        // We build the query with sqlx::QueryBuilder to keep optional
        // filters out of the SQL string when they aren't set. The
        // `(user_id = ? OR visibility = 'shared')` predicate mirrors
        // `Collections.list_collections/2` with `include_shared: true`.
        use sqlx::{Postgres, QueryBuilder, Sqlite};

        const COLS: &str = "id, name, description, type, visibility, is_system, user_id";

        match db {
            Db::Sqlite(pool) => {
                let mut qb: QueryBuilder<Sqlite> = QueryBuilder::new("SELECT ");
                qb.push(COLS);
                qb.push(" FROM collections WHERE (user_id = ");
                qb.push_bind(user_id.to_owned());
                qb.push(" OR visibility = 'shared')");
                if let Some(term) = search {
                    qb.push(" AND lower(name) LIKE ");
                    qb.push_bind(format!("%{term}%"));
                }
                if let Some(k) = kind {
                    qb.push(" AND type = ");
                    qb.push_bind(k.to_owned());
                }
                if let Some(v) = visibility {
                    qb.push(" AND visibility = ");
                    qb.push_bind(v.to_owned());
                }
                qb.push(" ORDER BY position ASC, name ASC");
                qb.build_query_as::<CollectionRow>()
                    .fetch_all(pool)
                    .await
                    .map_err(|err| ServerFnError::new(format!("list collections: {err}")))
            }
            Db::Postgres(pool) => {
                let mut qb: QueryBuilder<Postgres> = QueryBuilder::new("SELECT ");
                qb.push(COLS);
                qb.push(" FROM collections WHERE (user_id = ");
                qb.push_bind(user_id.to_owned());
                qb.push(" OR visibility = 'shared')");
                if let Some(term) = search {
                    qb.push(" AND lower(name) LIKE ");
                    qb.push_bind(format!("%{term}%"));
                }
                if let Some(k) = kind {
                    qb.push(" AND type = ");
                    qb.push_bind(k.to_owned());
                }
                if let Some(v) = visibility {
                    qb.push(" AND visibility = ");
                    qb.push_bind(v.to_owned());
                }
                qb.push(" ORDER BY position ASC, name ASC");
                qb.build_query_as::<CollectionRow>()
                    .fetch_all(pool)
                    .await
                    .map_err(|err| ServerFnError::new(format!("list collections: {err}")))
            }
        }
    }

    async fn fetch_collection_row(
        db: &Db,
        user_id: &str,
        id: &str,
    ) -> Result<CollectionRow, ServerFnError> {
        const COLS: &str = "id, name, description, type, visibility, is_system, user_id";

        let row: Option<CollectionRow> = match db {
            Db::Sqlite(pool) => {
                let sql = format!(
                    "SELECT {COLS} FROM collections \
                     WHERE id = ? AND (user_id = ? OR visibility = 'shared')"
                );
                sqlx::query_as(&sql)
                    .bind(id)
                    .bind(user_id)
                    .fetch_optional(pool)
                    .await
                    .map_err(|err| ServerFnError::new(format!("collection detail: {err}")))?
            }
            Db::Postgres(pool) => {
                let sql = format!(
                    "SELECT {COLS} FROM collections \
                     WHERE id = $1 AND (user_id = $2 OR visibility = 'shared')"
                );
                sqlx::query_as(&sql)
                    .bind(id)
                    .bind(user_id)
                    .fetch_optional(pool)
                    .await
                    .map_err(|err| ServerFnError::new(format!("collection detail: {err}")))?
            }
        };

        row.ok_or_else(|| ServerFnError::new("Collection not found"))
    }

    async fn count_manual_items(db: &Db, collection_id: &str) -> Result<i64, ServerFnError> {
        match db {
            Db::Sqlite(pool) => {
                let (n,): (i64,) =
                    sqlx::query_as("SELECT COUNT(*) FROM collection_items WHERE collection_id = ?")
                        .bind(collection_id)
                        .fetch_one(pool)
                        .await
                        .map_err(|err| ServerFnError::new(format!("count items: {err}")))?;
                Ok(n)
            }
            Db::Postgres(pool) => {
                let (n,): (i64,) = sqlx::query_as(
                    "SELECT COUNT(*) FROM collection_items WHERE collection_id = $1",
                )
                .bind(collection_id)
                .fetch_one(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("count items: {err}")))?;
                Ok(n)
            }
        }
    }

    async fn manual_poster_paths(
        db: &Db,
        collection_id: &str,
        limit: i64,
    ) -> Result<Vec<String>, ServerFnError> {
        // Walk the join in position order and pluck poster paths from
        // the embedded `metadata` JSON. The Phoenix helper does the same
        // shape — `metadata.poster_path` first, falling back to
        // collection-level `poster_path` (handled by the front-end via
        // a placeholder, not in this query).
        let sql_sqlite = "SELECT m.metadata FROM collection_items ci \
                          JOIN media_items m ON ci.media_item_id = m.id \
                          WHERE ci.collection_id = ? \
                          ORDER BY ci.position ASC LIMIT ?";
        let sql_pg = "SELECT m.metadata FROM collection_items ci \
                      JOIN media_items m ON ci.media_item_id = m.id \
                      WHERE ci.collection_id = $1 \
                      ORDER BY ci.position ASC LIMIT $2";

        let rows: Vec<(Option<String>,)> = match db {
            Db::Sqlite(pool) => sqlx::query_as(sql_sqlite)
                .bind(collection_id)
                .bind(limit)
                .fetch_all(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("poster paths: {err}")))?,
            Db::Postgres(pool) => sqlx::query_as(sql_pg)
                .bind(collection_id)
                .bind(limit)
                .fetch_all(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("poster paths: {err}")))?,
        };

        let mut out = Vec::with_capacity(rows.len());
        for (maybe_json,) in rows {
            if let Some(json) = maybe_json {
                if let Ok(v) = serde_json::from_str::<serde_json::Value>(&json) {
                    if let Some(p) = v.get("poster_path").and_then(|v| v.as_str()) {
                        out.push(p.to_owned());
                    }
                }
            }
        }
        Ok(out)
    }

    async fn fetch_manual_members(
        db: &Db,
        collection_id: &str,
    ) -> Result<Vec<CollectionMember>, ServerFnError> {
        type Row = (String, Option<String>, Option<i32>, String, Option<String>);

        let rows: Vec<Row> = match db {
            Db::Sqlite(pool) => sqlx::query_as(
                "SELECT m.id, m.title, m.year, m.type, m.metadata \
                 FROM collection_items ci \
                 JOIN media_items m ON ci.media_item_id = m.id \
                 WHERE ci.collection_id = ? \
                 ORDER BY ci.position ASC",
            )
            .bind(collection_id)
            .fetch_all(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("collection items: {err}")))?,
            Db::Postgres(pool) => sqlx::query_as(
                "SELECT m.id, m.title, m.year, m.type, m.metadata \
                 FROM collection_items ci \
                 JOIN media_items m ON ci.media_item_id = m.id \
                 WHERE ci.collection_id = $1 \
                 ORDER BY ci.position ASC",
            )
            .bind(collection_id)
            .fetch_all(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("collection items: {err}")))?,
        };

        Ok(rows
            .into_iter()
            .map(|(id, title, year, kind, metadata)| {
                let poster_path = metadata
                    .as_deref()
                    .and_then(|raw| serde_json::from_str::<serde_json::Value>(raw).ok())
                    .and_then(|v| {
                        v.get("poster_path")
                            .and_then(|p| p.as_str())
                            .map(std::borrow::ToOwned::to_owned)
                    });
                CollectionMember {
                    id,
                    title: title.unwrap_or_default(),
                    year,
                    kind,
                    poster_path,
                }
            })
            .collect())
    }
}
