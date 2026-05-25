//! Auth mutations — port of
//! `lib/mydia_web/schema/resolvers/auth_resolver.ex`.
//!
//! `login` validates username/password (also accepts email in the
//! username slot, matching Phoenix), updates `last_login_at`, and
//! issues a Guardian-shaped HS512 JWT with `typ: "access"`. The
//! returned `expires_in` is the difference between the token's `exp`
//! and `iat` claims, in seconds.
//!
//! The JWT signing secret comes from [`crate::context::GraphqlAppState`]
//! once the auth crate's `AccessTokenSigner` is registered there. In
//! U14 the resolver returns a clear error when no signer is attached
//! so the dependency surfaces explicitly during integration rather
//! than silently issuing tokens with a random key.

use std::time::Duration;

use async_graphql::{Context, Object};
use mydia_rs_auth::{verify_password, AccessTokenSigner};
use mydia_rs_db::types::{DateTimeSecs, UuidText};
use sea_orm::entity::prelude::*;
use sea_orm::Set;

use crate::context::GraphqlAppState;
use crate::repos::accounts;
use crate::types::{LoginInput, LoginResult, SetupAdminInput, UserObject, UserRow};

const TOKEN_TTL_SECS: u64 = 60 * 60 * 24 * 30; // 30 days — matches Guardian's default

#[derive(Default)]
pub struct AuthMutations;

#[Object]
impl AuthMutations {
    async fn login(
        &self,
        ctx: &Context<'_>,
        input: LoginInput,
    ) -> async_graphql::Result<LoginResult> {
        let state = ctx.data::<GraphqlAppState>()?;
        let signer = ctx
            .data_opt::<AccessTokenSigner>()
            .ok_or_else(|| async_graphql::Error::new("Token signer not configured"))?;

        // Try username first, then email — same fallback as Phoenix at
        // auth_resolver.ex:25-31.
        let user = match accounts::get_user_by_username(&state.db, &input.username).await? {
            Some(u) => Some(u),
            None => accounts::get_user_by_email(&state.db, &input.username).await?,
        };

        let user = user.ok_or_else(|| async_graphql::Error::new("Invalid username or password"))?;
        let password_hash = user
            .password_hash
            .as_deref()
            .ok_or_else(|| async_graphql::Error::new("Invalid username or password"))?;

        if verify_password(&input.password, password_hash).is_err() {
            return Err(async_graphql::Error::new("Invalid username or password"));
        }

        accounts::update_last_login(&state.db, &user.id.0.to_string()).await?;

        let issued = signer
            .issue(&user.id.0.to_string(), Duration::from_secs(TOKEN_TTL_SECS))
            .map_err(|err| {
                async_graphql::Error::new(format!("Failed to create authentication token: {err}"))
            })?;

        // input.device_id / device_name / platform are NOT used in
        // Phoenix's login resolver either (auth_resolver.ex:17-19
        // notes: "Note: This does NOT create a device record"). The
        // device pairing flow is a different surface — exercised via
        // the remote-access mutations in U29.
        let _ = (input.device_id, input.device_name, input.platform);

        let expires_in = issued.expires_in_secs() as i32;
        Ok(LoginResult {
            token: issued.token,
            user: UserObject {
                id: async_graphql::ID(user.id.0.to_string()),
                username: user.username,
                email: user.email,
                display_name: user.display_name,
            },
            expires_in,
        })
    }

    async fn setup_admin(
        &self,
        ctx: &Context<'_>,
        input: SetupAdminInput,
    ) -> async_graphql::Result<UserRow> {
        let state = ctx.data::<GraphqlAppState>()?;

        let existing_count = mydia_rs_entities::users::Entity::find()
            .count(&state.db)
            .await?;
        if existing_count > 0 {
            return Err(async_graphql::Error::new(
                "Setup already completed: users exist",
            ));
        }

        let username = input.username.trim().to_owned();
        if username.len() < 3 || username.len() > 50 {
            return Err(async_graphql::Error::new(
                "Username must be 3-50 characters",
            ));
        }
        let email = input.email.trim().to_owned();
        if !email.contains('@') || email.split_whitespace().count() != 1 {
            return Err(async_graphql::Error::new("Email must be a valid address"));
        }
        if input.password.len() < 8 {
            return Err(async_graphql::Error::new(
                "Password must be at least 8 characters",
            ));
        }

        let id = uuid::Uuid::new_v4();
        let id_str = id.to_string();
        let id_wrapper = UuidText::from(id);
        let now = DateTimeSecs::from(chrono::Utc::now());
        let hash = mydia_rs_auth::password::hash_password(&input.password)
            .map_err(|err| async_graphql::Error::new(format!("hash password: {err}")))?;

        let am = mydia_rs_entities::users::ActiveModel {
            id: Set(id_wrapper),
            username: Set(Some(username.clone())),
            email: Set(Some(email.clone())),
            password_hash: Set(Some(hash)),
            oidc_sub: Set(None),
            oidc_issuer: Set(None),
            role: Set("admin".to_owned()),
            display_name: Set(None),
            avatar_url: Set(None),
            last_login_at: Set(None),
            inserted_at: Set(now),
            updated_at: Set(now),
        };
        mydia_rs_db::insert_active_model(am, &state.db).await?;

        Ok(UserRow {
            id: async_graphql::ID(id_str),
            username: Some(username),
            email: Some(email),
            role: "admin".to_owned(),
            is_oidc: false,
            last_login_at: None,
            inserted_at: Some(now.0.to_rfc3339()),
        })
    }

    async fn logout(&self) -> async_graphql::Result<bool> {
        Ok(true)
    }
}
