use async_graphql::SimpleObject;
use chrono::{DateTime, Utc};
use mydia_rs_entities::sea_orm_active_enums::ObanJobState;

#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "WorkerSummary")]
pub struct WorkerSummary {
    pub queue: String,
    pub worker: String,
    pub count: i32,
    pub max_priority: Option<i32>,
    pub oldest_scheduled_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "JobEvent")]
pub struct JobEvent {
    pub id: i64,
    pub state: String,
    pub queue: String,
    pub worker: String,
    pub attempt: i32,
    pub max_attempts: i32,
    pub inserted_at: DateTime<Utc>,
    pub scheduled_at: DateTime<Utc>,
    pub attempted_at: Option<DateTime<Utc>>,
    pub completed_at: Option<DateTime<Utc>>,
    pub errors: Vec<String>,
    pub meta: Option<String>,
}

impl JobEvent {
    pub fn from_row(row: &mydia_rs_entities::oban_jobs::Model) -> Self {
        Self {
            id: row.id,
            state: oban_state_str(&row.state),
            queue: row.queue.clone(),
            worker: row.worker.clone(),
            attempt: row.attempt,
            max_attempts: row.max_attempts,
            inserted_at: row.inserted_at.0,
            scheduled_at: row.scheduled_at.0,
            attempted_at: row.attempted_at.map(|t| t.0),
            completed_at: row.completed_at.map(|t| t.0),
            errors: row
                .errors
                .iter()
                .filter_map(|v| v.as_str().map(std::borrow::ToOwned::to_owned))
                .collect(),
            meta: row
                .meta
                .as_ref()
                .and_then(|m| serde_json::to_string(&m.0).ok()),
        }
    }
}

fn oban_state_str(state: &ObanJobState) -> String {
    match state {
        ObanJobState::Available => "available".to_string(),
        ObanJobState::Scheduled => "scheduled".to_string(),
        ObanJobState::Executing => "executing".to_string(),
        ObanJobState::Retryable => "retryable".to_string(),
        ObanJobState::Completed => "completed".to_string(),
        ObanJobState::Discarded => "discarded".to_string(),
        ObanJobState::Cancelled => "cancelled".to_string(),
    }
}
