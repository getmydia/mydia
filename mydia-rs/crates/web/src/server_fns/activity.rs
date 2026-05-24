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
    use mydia_rs_db::types::DateTimeSecs;
    use mydia_rs_db::DatabaseConnection;
    use mydia_rs_entities::events;
    use sea_orm::entity::prelude::*;
    use sea_orm::query::{QueryOrder, QuerySelect};
    use sea_orm::sea_query::{Condition, Expr, ExprTrait};

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
        let page = Ord::max(query.page, 0);
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

    async fn fetch_events(
        db: &DatabaseConnection,
        category: &str,
        date_filter: &str,
        offset: i64,
        limit: i64,
    ) -> Result<Vec<events::Model>, ServerFnError> {
        let cat_filter = sanitize_category(category);
        let since_until = sanitize_date_filter(date_filter);
        let backend = db.get_database_backend();

        let mut cond = Condition::all();
        match cat_filter {
            CategoryFilter::All => {
                let mut any = Condition::any();
                for cat in ALLOWED_CATEGORIES {
                    any = any.add(events::Column::Category.eq((*cat).to_owned()));
                }
                cond = cond.add(any);
            }
            CategoryFilter::Errors => {
                cond = cond.add(events::Column::Severity.eq("error".to_owned()));
            }
            CategoryFilter::Category(cat) => {
                cond = cond.add(events::Column::Category.eq(cat.to_owned()));
            }
        }
        if let Some((since, until)) = since_until {
            let since_wrapper = DateTimeSecs::from(since);
            cond = cond.add(
                Expr::col(events::Column::InsertedAt).gte(since_wrapper.into_simple_expr(backend)),
            );
            if let Some(until) = until {
                let until_wrapper = DateTimeSecs::from(until);
                cond = cond.add(
                    Expr::col(events::Column::InsertedAt)
                        .lt(until_wrapper.into_simple_expr(backend)),
                );
            }
        }

        events::Entity::find()
            .filter(cond)
            .order_by_desc(events::Column::InsertedAt)
            .order_by_desc(events::Column::Id)
            .limit(u64::try_from(limit).unwrap_or(0))
            .offset(u64::try_from(offset).unwrap_or(0))
            .all(db)
            .await
            .map_err(|err| ServerFnError::new(format!("list events: {err}")))
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

    fn decode_row(row: events::Model) -> ActivityEvent {
        let metadata: serde_json::Value = row
            .metadata
            .as_deref()
            .and_then(|s| serde_json::from_str(s).ok())
            .unwrap_or(serde_json::Value::Object(serde_json::Map::new()));

        ActivityEvent {
            id: row.id.to_string(),
            category: row.category,
            event_type: row.r#type,
            severity: row.severity,
            actor_type: row.actor_type,
            actor_id: row.actor_id,
            metadata,
            inserted_at: row.inserted_at.0.to_rfc3339(),
        }
    }
}
