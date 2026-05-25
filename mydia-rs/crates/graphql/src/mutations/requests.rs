use async_graphql::{Context, InputObject, Object};
use mydia_rs_db::types::{DateTimeSecs, UuidText};
use sea_orm::Set;
use uuid::Uuid;

use crate::auth_guards::require_user;
use crate::context::GraphqlAppState;
use crate::types::MediaRequest;

#[derive(Debug, Clone, InputObject)]
#[graphql(name = "CreateMediaRequestInput")]
pub struct CreateMediaRequestInput {
    pub media_type: String,
    pub title: String,
    pub original_title: Option<String>,
    pub year: Option<i32>,
    pub tmdb_id: Option<i32>,
    pub imdb_id: Option<String>,
    pub requester_notes: Option<String>,
}

#[derive(Default)]
pub struct RequestMutations;

#[Object]
impl RequestMutations {
    async fn create_request(
        &self,
        ctx: &Context<'_>,
        input: CreateMediaRequestInput,
    ) -> async_graphql::Result<MediaRequest> {
        let user = require_user(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;

        let id = uuid::Uuid::new_v4();
        let now = DateTimeSecs::from(chrono::Utc::now());
        let requester_id = Uuid::parse_str(&user.id.to_string())
            .map(UuidText)
            .map_err(|e| async_graphql::Error::new(e.to_string()))?;

        let model = mydia_rs_entities::media_requests::ActiveModel {
            id: Set(UuidText(id)),
            media_type: Set(input.media_type),
            title: Set(input.title),
            original_title: Set(input.original_title),
            year: Set(input.year),
            tmdb_id: Set(input.tmdb_id),
            imdb_id: Set(input.imdb_id),
            status: Set("pending".to_string()),
            requester_notes: Set(input.requester_notes),
            admin_notes: Set(None),
            rejection_reason: Set(None),
            approved_at: Set(None),
            rejected_at: Set(None),
            requester_id: Set(requester_id),
            approved_by_id: Set(None),
            media_item_id: Set(None),
            inserted_at: Set(now),
            updated_at: Set(now),
            tvdb_id: Set(None),
        };

        let row = mydia_rs_db::insert_active_model(model, &state.db).await?;
        Ok(MediaRequest::from_row(&row))
    }
}
