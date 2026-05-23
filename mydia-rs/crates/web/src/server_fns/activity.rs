//! Activity feed server functions (U27).
//!
//! Phoenix counterpart: `MydiaWeb.ActivityLive.Index` +
//! `Mydia.Events.list_events/1`. The Phoenix page is a paginated,
//! filterable chronological feed of every recorded event; the Rust
//! port mirrors the same filter taxonomy (category, severity, date
//! preset) but trims the surface to "fetch a page" — real-time fan-out
//! lands as a follow-up if/when the activity page warrants it.
//!
//! Music/Books/Adult are not present in any new write paths from the
//! Rust pipeline, but old events still exist in the `events` table.
//! The page filters them out at the server boundary so the operator
//! audience doesn't see deprecated domains in their feed.

use dioxus::fullstack::ServerFnError;
use dioxus::prelude::*;
use serde::{Deserialize, Serialize};

/// Default page size, matching `@page_size` in
/// `lib/mydia_web/live/activity_live/index.ex`.
pub const PAGE_SIZE: i64 = 50;

/// Categories included in the activity feed — deliberately a subset
/// of the full events taxonomy. Music / books / adult are excluded.
pub const ALLOWED_CATEGORIES: &[&str] = &["media_item", "download", "job", "search"];

/// One event row as the activity feed renders it. The metadata field
/// stays as raw JSON so the wire shape mirrors the Phoenix
/// `Mydia.Events.Event` struct closely (the rendering layer plucks
/// fields by key).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ActivityEvent {
    pub id: String,
    pub category: String,
    #[serde(rename = "type")]
    pub event_type: String,
    pub severity: String,
    #[serde(default)]
    pub actor_type: Option<String>,
    #[serde(default)]
    pub actor_id: Option<String>,
    #[serde(default)]
    pub metadata: serde_json::Value,
    /// RFC3339 string — server-side rendered so the wasm client doesn't
    /// reach for `chrono` to format.
    pub inserted_at: String,
}

/// Query payload — drives the filter pills and pagination cursor.
///
/// The `date_filter` and `category` fields take the same string
/// vocabulary as the Phoenix `phx-click="filter_*"` events
/// (`"all" / "today" / "yesterday" / "week" / "month"` and
/// `"all" / "errors" / "media_item" / "download" / "job" / "search"`).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ActivityQuery {
    #[serde(default = "default_filter_all")]
    pub category: String,
    #[serde(default = "default_filter_all")]
    pub date_filter: String,
    #[serde(default)]
    pub page: i64,
}

fn default_filter_all() -> String {
    "all".to_owned()
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ActivityPage {
    pub events: Vec<ActivityEvent>,
    pub has_more: bool,
}

#[get("/api/activity")]
pub async fn list_activity(query: ActivityQuery) -> Result<ActivityPage, ServerFnError> {
    server::list(query).await
}

#[cfg(feature = "server")]
mod server {
    use super::{ActivityEvent, ActivityPage, ActivityQuery, ALLOWED_CATEGORIES, PAGE_SIZE};
    use crate::server_fns::auth::require_session_user_id;
    use crate::server_state::WebState;
    use chrono::{DateTime, Duration as ChronoDuration, Utc};
    use dioxus::fullstack::{FullstackContext, ServerFnError};
    use mydia_rs_db::Db;

    fn state() -> Result<WebState, ServerFnError> {
        let ctx = FullstackContext::current()
            .ok_or_else(|| ServerFnError::new("no fullstack context"))?;
        ctx.extension::<WebState>()
            .ok_or_else(|| ServerFnError::new("WebState extension missing"))
    }

    pub(super) async fn list(query: ActivityQuery) -> Result<ActivityPage, ServerFnError> {
        require_session_user_id().await?;
        let st = state()?;

        // Phoenix asks for `PAGE_SIZE + 1` and uses the +1 to detect
        // "has_more"; we do the same so the wire contract stays the
        // same.
        let page = query.page.max(0);
        let offset = page * PAGE_SIZE;
        let limit = PAGE_SIZE + 1;

        let rows = fetch_events(&st.db, &query.category, &query.date_filter, offset, limit).await?;

        let has_more = rows.len() as i64 > PAGE_SIZE;
        let events: Vec<ActivityEvent> = rows
            .into_iter()
            .take(PAGE_SIZE as usize)
            .map(decode_row)
            .collect();

        Ok(ActivityPage { events, has_more })
    }

    /// `(id, category, type, severity, actor_type, actor_id, metadata_json, inserted_at)`.
    type EventRow = (
        String,
        String,
        String,
        String,
        Option<String>,
        Option<String>,
        Option<String>,
        chrono::DateTime<chrono::Utc>,
    );

    async fn fetch_events(
        db: &Db,
        category: &str,
        date_filter: &str,
        offset: i64,
        limit: i64,
    ) -> Result<Vec<EventRow>, ServerFnError> {
        // Whitelist the categories: either "all"/"errors", a specific
        // allowed one, or otherwise return nothing. The OR-IN clause
        // (rather than IN with a placeholder list) keeps the query
        // shape constant across dialects.
        let cat_filter = sanitize_category(category);
        let since_until = sanitize_date_filter(date_filter);

        match db {
            Db::Sqlite(pool) => {
                let mut qb = sqlx::QueryBuilder::<sqlx::Sqlite>::new(
                    "SELECT id, category, type, severity, actor_type, actor_id, metadata, inserted_at \
                     FROM events WHERE 1=1",
                );
                apply_category_filter_sqlite(&mut qb, &cat_filter);
                if let Some((since, until)) = since_until {
                    qb.push(" AND inserted_at >= ").push_bind(since);
                    if let Some(until) = until {
                        qb.push(" AND inserted_at < ").push_bind(until);
                    }
                }
                qb.push(" ORDER BY inserted_at DESC, id DESC");
                qb.push(" LIMIT ").push_bind(limit);
                qb.push(" OFFSET ").push_bind(offset);
                qb.build_query_as::<EventRow>()
                    .fetch_all(pool)
                    .await
                    .map_err(|err| ServerFnError::new(format!("list events: {err}")))
            }
            Db::Postgres(pool) => {
                let mut qb = sqlx::QueryBuilder::<sqlx::Postgres>::new(
                    "SELECT id, category, type, severity, actor_type, actor_id, metadata::text, inserted_at \
                     FROM events WHERE 1=1",
                );
                apply_category_filter_postgres(&mut qb, &cat_filter);
                if let Some((since, until)) = since_until {
                    qb.push(" AND inserted_at >= ").push_bind(since);
                    if let Some(until) = until {
                        qb.push(" AND inserted_at < ").push_bind(until);
                    }
                }
                qb.push(" ORDER BY inserted_at DESC, id DESC");
                qb.push(" LIMIT ").push_bind(limit);
                qb.push(" OFFSET ").push_bind(offset);
                qb.build_query_as::<EventRow>()
                    .fetch_all(pool)
                    .await
                    .map_err(|err| ServerFnError::new(format!("list events: {err}")))
            }
        }
    }

    enum CategoryFilter {
        All,
        Errors,
        Category(&'static str),
    }

    fn sanitize_category(s: &str) -> CategoryFilter {
        match s {
            "all" => CategoryFilter::All,
            "errors" => CategoryFilter::Errors,
            other => {
                if let Some(cat) = ALLOWED_CATEGORIES.iter().find(|c| **c == other) {
                    CategoryFilter::Category(cat)
                } else {
                    CategoryFilter::All
                }
            }
        }
    }

    fn apply_category_filter_sqlite(
        qb: &mut sqlx::QueryBuilder<'_, sqlx::Sqlite>,
        f: &CategoryFilter,
    ) {
        match f {
            CategoryFilter::All => {
                qb.push(" AND category IN (");
                let mut sep = qb.separated(", ");
                for cat in ALLOWED_CATEGORIES {
                    sep.push_bind((*cat).to_owned());
                }
                qb.push(")");
            }
            CategoryFilter::Errors => {
                qb.push(" AND severity = ").push_bind("error".to_owned());
            }
            CategoryFilter::Category(cat) => {
                qb.push(" AND category = ").push_bind((*cat).to_owned());
            }
        }
    }

    fn apply_category_filter_postgres(
        qb: &mut sqlx::QueryBuilder<'_, sqlx::Postgres>,
        f: &CategoryFilter,
    ) {
        match f {
            CategoryFilter::All => {
                qb.push(" AND category IN (");
                let mut sep = qb.separated(", ");
                for cat in ALLOWED_CATEGORIES {
                    sep.push_bind((*cat).to_owned());
                }
                qb.push(")");
            }
            CategoryFilter::Errors => {
                qb.push(" AND severity = ").push_bind("error".to_owned());
            }
            CategoryFilter::Category(cat) => {
                qb.push(" AND category = ").push_bind((*cat).to_owned());
            }
        }
    }

    fn sanitize_date_filter(s: &str) -> Option<(DateTime<Utc>, Option<DateTime<Utc>>)> {
        let now = Utc::now();
        match s {
            "today" => Some((start_of_day(now), None)),
            "yesterday" => {
                let start_today = start_of_day(now);
                let start_yesterday = start_today - ChronoDuration::days(1);
                Some((start_yesterday, Some(start_today)))
            }
            "week" => Some((now - ChronoDuration::days(7), None)),
            "month" => Some((now - ChronoDuration::days(30), None)),
            _ => None,
        }
    }

    fn start_of_day(now: DateTime<Utc>) -> DateTime<Utc> {
        let date = now.date_naive();
        date.and_hms_opt(0, 0, 0).map_or(now, |naive| {
            DateTime::<Utc>::from_naive_utc_and_offset(naive, Utc)
        })
    }

    fn decode_row(row: EventRow) -> ActivityEvent {
        let metadata: serde_json::Value = row
            .6
            .as_deref()
            .and_then(|s| serde_json::from_str(s).ok())
            .unwrap_or(serde_json::Value::Object(serde_json::Map::new()));

        ActivityEvent {
            id: row.0,
            category: row.1,
            event_type: row.2,
            severity: row.3,
            actor_type: row.4,
            actor_id: row.5,
            metadata,
            inserted_at: row.7.to_rfc3339(),
        }
    }
}
