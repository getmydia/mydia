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
    use mydia_rs_db::types::UuidText;
    use mydia_rs_db::DatabaseConnection;
    use mydia_rs_entities::{collection_items, collections, media_items};
    use sea_orm::entity::prelude::*;
    use sea_orm::query::{QueryOrder, QuerySelect};
    use sea_orm::sea_query::{Condition, Expr, ExprTrait, Func};

    fn state() -> Result<WebState, ServerFnError> {
        let ctx = FullstackContext::current()
            .ok_or_else(|| ServerFnError::new("no fullstack context"))?;
        ctx.extension::<WebState>()
            .ok_or_else(|| ServerFnError::new("WebState extension missing"))
    }

    fn parse_uuid(s: &str) -> Option<UuidText> {
        uuid::Uuid::parse_str(s).ok().map(UuidText::from)
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
        db: &DatabaseConnection,
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
        db: &DatabaseConnection,
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
        db: &DatabaseConnection,
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

    fn model_to_row(m: collections::Model) -> CollectionRow {
        (
            m.id.to_string(),
            m.name,
            m.description,
            m.r#type,
            m.visibility,
            m.is_system,
            m.user_id.to_string(),
        )
    }

    async fn fetch_collection_rows(
        db: &DatabaseConnection,
        user_id: &str,
        search: Option<&str>,
        kind: Option<&str>,
        visibility: Option<&str>,
    ) -> Result<Vec<CollectionRow>, ServerFnError> {
        let Some(user_wrapper) = parse_uuid(user_id) else {
            return Ok(Vec::new());
        };
        let backend = db.get_database_backend();
        let mut cond = Condition::all();
        cond = cond.add(
            Condition::any()
                .add(
                    Expr::col(collections::Column::UserId)
                        .eq(user_wrapper.into_simple_expr(backend)),
                )
                .add(collections::Column::Visibility.eq("shared".to_owned())),
        );
        if let Some(term) = search {
            cond = cond.add(
                Expr::expr(Func::lower(Expr::col(collections::Column::Name)))
                    .like(format!("%{term}%")),
            );
        }
        if let Some(k) = kind {
            cond = cond.add(collections::Column::Type.eq(k.to_owned()));
        }
        if let Some(v) = visibility {
            cond = cond.add(collections::Column::Visibility.eq(v.to_owned()));
        }
        let rows = collections::Entity::find()
            .filter(cond)
            .order_by_asc(collections::Column::Position)
            .order_by_asc(collections::Column::Name)
            .all(db)
            .await
            .map_err(|err| ServerFnError::new(format!("list collections: {err}")))?;
        Ok(rows.into_iter().map(model_to_row).collect())
    }

    async fn fetch_collection_row(
        db: &DatabaseConnection,
        user_id: &str,
        id: &str,
    ) -> Result<CollectionRow, ServerFnError> {
        let Some(id_wrapper) = parse_uuid(id) else {
            return Err(ServerFnError::new("Collection not found"));
        };
        let backend = db.get_database_backend();
        let row = collections::Entity::find()
            .filter(Expr::col(collections::Column::Id).eq(id_wrapper.into_simple_expr(backend)))
            .one(db)
            .await
            .map_err(|err| ServerFnError::new(format!("collection detail: {err}")))?
            .ok_or_else(|| ServerFnError::new("Collection not found"))?;
        // Authz check: belongs to user or shared visibility.
        let user_match = user_id == row.user_id.to_string();
        if !user_match && row.visibility != "shared" {
            return Err(ServerFnError::new("Collection not found"));
        }
        Ok(model_to_row(row))
    }

    async fn count_manual_items(
        db: &DatabaseConnection,
        collection_id: &str,
    ) -> Result<i64, ServerFnError> {
        let Some(wrapper) = parse_uuid(collection_id) else {
            return Ok(0);
        };
        let backend = db.get_database_backend();
        let n = collection_items::Entity::find()
            .filter(
                Expr::col(collection_items::Column::CollectionId)
                    .eq(wrapper.into_simple_expr(backend)),
            )
            .count(db)
            .await
            .map_err(|err| ServerFnError::new(format!("count items: {err}")))?;
        Ok(i64::try_from(n).unwrap_or(i64::MAX))
    }

    async fn manual_poster_paths(
        db: &DatabaseConnection,
        collection_id: &str,
        limit: i64,
    ) -> Result<Vec<String>, ServerFnError> {
        let Some(wrapper) = parse_uuid(collection_id) else {
            return Ok(Vec::new());
        };
        let backend = db.get_database_backend();
        let items = collection_items::Entity::find()
            .filter(
                Expr::col(collection_items::Column::CollectionId)
                    .eq(wrapper.into_simple_expr(backend)),
            )
            .order_by_asc(collection_items::Column::Position)
            .limit(u64::try_from(limit).unwrap_or(4))
            .all(db)
            .await
            .map_err(|err| ServerFnError::new(format!("poster paths: {err}")))?;
        if items.is_empty() {
            return Ok(Vec::new());
        }
        let media_ids: Vec<UuidText> = items.iter().map(|ci| ci.media_item_id).collect();
        let media = media_items::Entity::find()
            .filter(media_items::Column::Id.is_in(media_ids))
            .all(db)
            .await
            .map_err(|err| ServerFnError::new(format!("poster paths media_items: {err}")))?;
        let by_id: std::collections::HashMap<UuidText, media_items::Model> =
            media.into_iter().map(|m| (m.id, m)).collect();
        let mut out = Vec::with_capacity(items.len());
        for ci in items {
            if let Some(m) = by_id.get(&ci.media_item_id) {
                if let Some(json) = m.metadata.as_deref() {
                    if let Ok(v) = serde_json::from_str::<serde_json::Value>(json) {
                        if let Some(p) = v.get("poster_path").and_then(|x| x.as_str()) {
                            out.push(p.to_owned());
                        }
                    }
                }
            }
        }
        Ok(out)
    }

    async fn fetch_manual_members(
        db: &DatabaseConnection,
        collection_id: &str,
    ) -> Result<Vec<CollectionMember>, ServerFnError> {
        let Some(wrapper) = parse_uuid(collection_id) else {
            return Ok(Vec::new());
        };
        let backend = db.get_database_backend();
        let items = collection_items::Entity::find()
            .filter(
                Expr::col(collection_items::Column::CollectionId)
                    .eq(wrapper.into_simple_expr(backend)),
            )
            .order_by_asc(collection_items::Column::Position)
            .all(db)
            .await
            .map_err(|err| ServerFnError::new(format!("collection items: {err}")))?;
        if items.is_empty() {
            return Ok(Vec::new());
        }
        let media_ids: Vec<UuidText> = items.iter().map(|ci| ci.media_item_id).collect();
        let media = media_items::Entity::find()
            .filter(media_items::Column::Id.is_in(media_ids))
            .all(db)
            .await
            .map_err(|err| ServerFnError::new(format!("collection items media: {err}")))?;
        let by_id: std::collections::HashMap<UuidText, media_items::Model> =
            media.into_iter().map(|m| (m.id, m)).collect();
        Ok(items
            .into_iter()
            .filter_map(|ci| {
                let m = by_id.get(&ci.media_item_id)?;
                let poster_path = m
                    .metadata
                    .as_deref()
                    .and_then(|raw| serde_json::from_str::<serde_json::Value>(raw).ok())
                    .and_then(|v| {
                        v.get("poster_path")
                            .and_then(|p| p.as_str())
                            .map(std::borrow::ToOwned::to_owned)
                    });
                Some(CollectionMember {
                    id: m.id.to_string(),
                    title: m.title.clone(),
                    year: m.year,
                    kind: m.r#type.clone(),
                    poster_path,
                })
            })
            .collect())
    }
}
