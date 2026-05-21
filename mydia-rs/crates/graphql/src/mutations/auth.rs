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

use crate::context::GraphqlAppState;
use crate::repos::accounts;
use crate::types::{LoginInput, LoginResult, UserObject};

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
}
