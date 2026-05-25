use async_graphql::{Context, Object, ID};
use mydia_rs_db::types::{DateTimeSecs, UuidText};
use sea_orm::entity::prelude::*;
use sea_orm::sea_query::{Expr, ExprTrait};
use sea_orm::Set;

use crate::auth_guards::require_admin;
use crate::context::GraphqlAppState;
use crate::types::{CreateUserInput, UpdateUserRoleInput, UserRow};

const VALID_ROLES: &[&str] = &["admin", "user", "readonly", "guest"];

fn parse_id(id: &str) -> async_graphql::Result<UuidText> {
    uuid::Uuid::parse_str(id)
        .map(UuidText)
        .map_err(|_| async_graphql::Error::new("Invalid id format"))
}

fn validate_new_user(input: &CreateUserInput) -> async_graphql::Result<()> {
    let username = input.username.trim();
    if !(3..=50).contains(&username.chars().count()) {
        return Err(async_graphql::Error::new(
            "Username must be 3-50 characters",
        ));
    }
    let email = input.email.trim();
    if !email.contains('@') || email.split_whitespace().count() != 1 {
        return Err(async_graphql::Error::new("Email must be a valid address"));
    }
    if input.password.chars().count() < 8 {
        return Err(async_graphql::Error::new(
            "Password must be at least 8 characters",
        ));
    }
    Ok(())
}

#[derive(Default)]
pub struct UserMutations;

#[Object]
impl UserMutations {
    async fn create_user(
        &self,
        ctx: &Context<'_>,
        input: CreateUserInput,
    ) -> async_graphql::Result<UserRow> {
        require_admin(ctx)?;
        validate_new_user(&input)?;

        let state = ctx.data::<GraphqlAppState>()?;
        let role = if input.role.as_deref().unwrap_or("").trim().is_empty() {
            "guest"
        } else {
            input.role.as_deref().unwrap_or("guest").trim()
        };

        if !VALID_ROLES.contains(&role) {
            return Err(async_graphql::Error::new(format!(
                "invalid role {role:?}; must be one of {VALID_ROLES:?}"
            )));
        }

        let id = uuid::Uuid::new_v4();
        let id_str = id.to_string();
        let id_wrapper = UuidText::from(id);
        let now = DateTimeSecs::from(chrono::Utc::now());
        let hash = mydia_rs_auth::password::hash_password(&input.password)
            .map_err(|err| async_graphql::Error::new(format!("hash password: {err}")))?;

        let username = input.username.trim().to_owned();
        let email = input.email.trim().to_owned();

        let am = mydia_rs_entities::users::ActiveModel {
            id: Set(id_wrapper),
            username: Set(Some(username.clone())),
            email: Set(Some(email.clone())),
            password_hash: Set(Some(hash)),
            oidc_sub: Set(None),
            oidc_issuer: Set(None),
            role: Set(role.to_owned()),
            display_name: Set(None),
            avatar_url: Set(None),
            last_login_at: Set(None),
            inserted_at: Set(now),
            updated_at: Set(now),
        };
        mydia_rs_db::insert_active_model(am, &state.db).await?;

        Ok(UserRow {
            id: ID(id_str),
            username: Some(username),
            email: Some(email),
            role: role.to_owned(),
            is_oidc: false,
            last_login_at: None,
            inserted_at: Some(now.0.to_rfc3339()),
        })
    }

    async fn update_user_role(
        &self,
        ctx: &Context<'_>,
        input: UpdateUserRoleInput,
    ) -> async_graphql::Result<UserRow> {
        let current_user = require_admin(ctx)?;
        let target_id_str = input.id.as_str();

        if current_user.id.to_string() == target_id_str {
            return Err(async_graphql::Error::new("Cannot change your own role"));
        }

        if !VALID_ROLES.contains(&input.role.as_str()) {
            return Err(async_graphql::Error::new(format!(
                "invalid role {:?}; must be one of {VALID_ROLES:?}",
                input.role
            )));
        }

        let state = ctx.data::<GraphqlAppState>()?;
        let wrapper = parse_id(target_id_str)?;
        let backend = state.db.get_database_backend();
        let now = DateTimeSecs::from(chrono::Utc::now());

        let res = mydia_rs_entities::users::Entity::update_many()
            .col_expr(
                mydia_rs_entities::users::Column::Role,
                Expr::value(input.role.clone()),
            )
            .col_expr(
                mydia_rs_entities::users::Column::UpdatedAt,
                now.into_simple_expr(backend),
            )
            .filter(
                Expr::col(mydia_rs_entities::users::Column::Id)
                    .eq(wrapper.into_simple_expr(backend)),
            )
            .exec(&state.db)
            .await?;

        if res.rows_affected == 0 {
            return Err(async_graphql::Error::new(format!(
                "no user with id {target_id_str}"
            )));
        }

        let updated = mydia_rs_entities::users::Entity::find_by_id(wrapper)
            .one(&state.db)
            .await?
            .ok_or_else(|| async_graphql::Error::new("user disappeared between update and read"))?;

        Ok(UserRow {
            id: ID(updated.id.0.to_string()),
            username: updated.username,
            email: updated.email,
            role: updated.role,
            is_oidc: updated.oidc_sub.is_some(),
            last_login_at: updated.last_login_at.map(|dt| dt.0.to_rfc3339()),
            inserted_at: Some(updated.inserted_at.0.to_rfc3339()),
        })
    }

    async fn delete_user(&self, ctx: &Context<'_>, id: ID) -> async_graphql::Result<bool> {
        let current_user = require_admin(ctx)?;
        let target_id_str = id.as_str();

        if current_user.id.to_string() == target_id_str {
            return Err(async_graphql::Error::new(
                "You cannot delete your own account",
            ));
        }

        let state = ctx.data::<GraphqlAppState>()?;
        let wrapper = parse_id(target_id_str)?;
        let backend = state.db.get_database_backend();

        let res = mydia_rs_entities::users::Entity::delete_many()
            .filter(
                Expr::col(mydia_rs_entities::users::Column::Id)
                    .eq(wrapper.into_simple_expr(backend)),
            )
            .exec(&state.db)
            .await?;

        if res.rows_affected == 0 {
            return Err(async_graphql::Error::new(format!(
                "no user with id {target_id_str}"
            )));
        }

        Ok(true)
    }
}
