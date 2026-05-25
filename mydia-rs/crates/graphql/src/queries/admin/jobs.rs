use async_graphql::{Context, Object};
use sea_orm::entity::prelude::*;
use sea_orm::{QueryOrder, QuerySelect};
use std::collections::HashMap;

use crate::auth_guards::require_admin;
use crate::context::GraphqlAppState;
use crate::types::{JobEvent, WorkerSummary};

#[derive(Default)]
pub struct JobQueries;

#[Object]
impl JobQueries {
    async fn worker_summary(&self, ctx: &Context<'_>) -> async_graphql::Result<Vec<WorkerSummary>> {
        require_admin(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;

        let rows = mydia_rs_entities::oban_jobs::Entity::find()
            .filter(mydia_rs_entities::oban_jobs::Column::State.is_in([
                "available",
                "executing",
                "scheduled",
                "retryable",
            ]))
            .all(&state.db)
            .await?;

        type WorkerGroup = (i32, Option<i32>, Option<chrono::DateTime<chrono::Utc>>);
        let mut groups: HashMap<(String, String), WorkerGroup> = HashMap::new();
        for row in &rows {
            let key = (row.queue.clone(), row.worker.clone());
            let entry = groups.entry(key).or_insert((0, None, None));
            entry.0 += 1;
            if let Some(prio) = entry.1 {
                entry.1 = Some(prio.max(row.priority));
            } else {
                entry.1 = Some(row.priority);
            }
            if let Some(existing) = entry.2 {
                let sched = row.scheduled_at.0;
                if sched < existing {
                    entry.2 = Some(sched);
                }
            } else {
                entry.2 = Some(row.scheduled_at.0);
            }
        }

        let mut summaries: Vec<WorkerSummary> = groups
            .into_iter()
            .map(
                |((queue, worker), (count, max_priority, oldest_scheduled_at))| WorkerSummary {
                    queue,
                    worker,
                    count,
                    max_priority,
                    oldest_scheduled_at,
                },
            )
            .collect();
        summaries.sort_by(|a, b| a.queue.cmp(&b.queue).then_with(|| b.count.cmp(&a.count)));
        Ok(summaries)
    }

    async fn recent_job_events(
        &self,
        ctx: &Context<'_>,
        #[graphql(default = 50)] limit: i32,
    ) -> async_graphql::Result<Vec<JobEvent>> {
        require_admin(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;

        let rows = mydia_rs_entities::oban_jobs::Entity::find()
            .order_by_desc(mydia_rs_entities::oban_jobs::Column::InsertedAt)
            .limit(limit.clamp(1, 200) as u64)
            .all(&state.db)
            .await?;

        Ok(rows.iter().map(JobEvent::from_row).collect())
    }
}
