//! Authentication for the byte-serving endpoints.
//!
//! The player sends two different things depending on how it paired
//! (player_screen.dart:893-916):
//!
//! - password mode sends its regular **access** token in an Authorization
//!   header and no query token,
//! - claim code mode appends `?token=<media token>` and sets no header.
//!
//! Accepting only one of those would break half the installs, so both are
//! accepted from either transport, which is also what
//! `MydiaWeb.Plugs.MediaAuth` does (media_auth.ex:6-7).

use axum::http::{HeaderMap, StatusCode};
use mydia_auth::tokens::{Issuer, TokenKind};

/// The permission a media token needs to stream (router.ex:62). Access tokens
/// carry no permissions and do not need this: holding one already means being
/// logged in.
const STREAM_PERMISSION: &str = "stream";

/// Returns the caller's user id, or the status the request should fail with.
pub fn authorize(
    issuer: &Issuer,
    headers: &HeaderMap,
    query_token: Option<&str>,
) -> Result<String, StatusCode> {
    let presented = bearer(headers)
        .or_else(|| query_token.map(str::to_string))
        .ok_or(StatusCode::UNAUTHORIZED)?;

    // An access token is the common case, so it is tried first.
    if let Ok(claims) = issuer.verify(&presented, TokenKind::Access) {
        return Ok(claims.sub);
    }

    let claims = issuer
        .verify(&presented, TokenKind::Media)
        .map_err(|_| StatusCode::UNAUTHORIZED)?;

    if !claims.permissions.iter().any(|p| p == STREAM_PERMISSION) {
        return Err(StatusCode::FORBIDDEN);
    }

    Ok(claims.sub)
}

fn bearer(headers: &HeaderMap) -> Option<String> {
    headers
        .get(axum::http::header::AUTHORIZATION)?
        .to_str()
        .ok()?
        .strip_prefix("Bearer ")
        .map(str::to_string)
}

#[cfg(test)]
mod tests {
    use super::authorize;
    use axum::http::{HeaderMap, HeaderValue, StatusCode};
    use mydia_auth::tokens::{Issuer, TokenKind};

    fn issuer() -> Issuer {
        Issuer::new(b"test-secret-that-is-long-enough-for-hs256")
    }

    fn bearer(token: &str) -> HeaderMap {
        let mut headers = HeaderMap::new();
        headers.insert(
            axum::http::header::AUTHORIZATION,
            HeaderValue::from_str(&format!("Bearer {token}")).unwrap(),
        );
        headers
    }

    #[test]
    fn an_access_token_in_the_header_is_accepted() {
        // Password mode: player_screen.dart:914 sets this header and sends no
        // query token at all.
        let iss = issuer();
        let (token, _) = iss.issue("user-1", TokenKind::Access, Vec::new()).unwrap();

        assert_eq!(authorize(&iss, &bearer(&token), None).unwrap(), "user-1");
    }

    #[test]
    fn a_media_token_in_the_query_is_accepted() {
        // Claim code mode: streaming_strategy.dart:69 appends ?token=.
        let iss = issuer();
        let (token, _) = iss
            .issue("user-2", TokenKind::Media, vec!["stream".to_string()])
            .unwrap();

        assert_eq!(
            authorize(&iss, &HeaderMap::new(), Some(&token)).unwrap(),
            "user-2"
        );
    }

    #[test]
    fn a_media_token_in_the_header_is_also_accepted() {
        // media_auth.ex:6-7 accepts either transport for either token.
        let iss = issuer();
        let (token, _) = iss
            .issue("user-3", TokenKind::Media, vec!["stream".to_string()])
            .unwrap();

        assert_eq!(authorize(&iss, &bearer(&token), None).unwrap(), "user-3");
    }

    #[test]
    fn a_media_token_without_the_stream_permission_is_refused() {
        // router.ex:62 requires permissions: ["stream"].
        let iss = issuer();
        let (token, _) = iss.issue("user-4", TokenKind::Media, Vec::new()).unwrap();

        assert_eq!(
            authorize(&iss, &HeaderMap::new(), Some(&token)).unwrap_err(),
            StatusCode::FORBIDDEN
        );
    }

    #[test]
    fn no_token_at_all_is_unauthorized() {
        assert_eq!(
            authorize(&issuer(), &HeaderMap::new(), None).unwrap_err(),
            StatusCode::UNAUTHORIZED
        );
    }

    #[test]
    fn a_refresh_token_cannot_stream() {
        let iss = issuer();
        let (token, _) = iss.issue("user-5", TokenKind::Refresh, Vec::new()).unwrap();

        assert_eq!(
            authorize(&iss, &bearer(&token), None).unwrap_err(),
            StatusCode::UNAUTHORIZED
        );
    }
}
