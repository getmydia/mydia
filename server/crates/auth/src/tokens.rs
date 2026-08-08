use chrono::{DateTime, Duration, Utc};
use jsonwebtoken::{decode, encode, DecodingKey, EncodingKey, Header, Validation};
use serde::{Deserialize, Serialize};

use crate::AuthError;

/// Access tokens authenticate GraphQL requests. Refresh tokens buy new
/// access tokens. Media tokens authorize byte-serving endpoints and are
/// deliberately short-lived, because playlist URLs carrying them travel
/// further than the other two.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TokenKind {
    Access,
    Refresh,
    Media,
}

impl TokenKind {
    fn audience(self) -> &'static str {
        match self {
            TokenKind::Access => "mydia:access",
            TokenKind::Refresh => "mydia:refresh",
            TokenKind::Media => "mydia:media",
        }
    }

    fn lifetime(self) -> Duration {
        match self {
            TokenKind::Access => Duration::hours(1),
            TokenKind::Refresh => Duration::days(30),
            TokenKind::Media => Duration::minutes(15),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Claims {
    /// User id.
    pub sub: String,
    /// Token kind, as an audience string.
    pub aud: String,
    /// Expiry, seconds since the epoch.
    pub exp: i64,
    /// Issued at, seconds since the epoch.
    pub iat: i64,
    #[serde(default)]
    pub permissions: Vec<String>,
}

#[derive(Clone)]
pub struct Issuer {
    encoding: EncodingKey,
    decoding: DecodingKey,
}

impl std::fmt::Debug for Issuer {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // Never render the key material.
        f.write_str("Issuer { .. }")
    }
}

impl Issuer {
    pub fn new(secret: &[u8]) -> Self {
        Self {
            encoding: EncodingKey::from_secret(secret),
            decoding: DecodingKey::from_secret(secret),
        }
    }

    pub fn issue(
        &self,
        user_id: &str,
        kind: TokenKind,
        permissions: Vec<String>,
    ) -> Result<(String, DateTime<Utc>), AuthError> {
        let now = Utc::now();
        let expires_at = now + kind.lifetime();

        let claims = Claims {
            sub: user_id.to_string(),
            aud: kind.audience().to_string(),
            exp: expires_at.timestamp(),
            iat: now.timestamp(),
            permissions,
        };

        let token =
            encode(&Header::default(), &claims, &self.encoding).map_err(AuthError::Issue)?;

        Ok((token, expires_at))
    }

    pub fn verify(&self, token: &str, kind: TokenKind) -> Result<Claims, AuthError> {
        let mut validation = Validation::default();
        validation.set_audience(&[kind.audience()]);

        decode::<Claims>(token, &self.decoding, &validation)
            .map(|data| data.claims)
            .map_err(|_| AuthError::InvalidToken)
    }
}

#[cfg(test)]
mod tests {
    use super::{Issuer, TokenKind};

    fn issuer() -> Issuer {
        Issuer::new(b"test-secret-that-is-long-enough-for-hs256")
    }

    #[test]
    fn an_access_token_round_trips() {
        let iss = issuer();
        let (token, expires_at) = iss.issue("user-1", TokenKind::Access, vec![]).unwrap();

        let claims = iss.verify(&token, TokenKind::Access).unwrap();

        assert_eq!(claims.sub, "user-1");
        assert!(expires_at > chrono::Utc::now());
    }

    #[test]
    fn a_media_token_carries_permissions() {
        let iss = issuer();
        let (token, _) = iss
            .issue("user-1", TokenKind::Media, vec!["stream".to_string()])
            .unwrap();

        let claims = iss.verify(&token, TokenKind::Media).unwrap();

        assert_eq!(claims.permissions, vec!["stream".to_string()]);
    }

    #[test]
    fn a_refresh_token_is_rejected_as_a_media_token() {
        let iss = issuer();
        let (token, _) = iss.issue("user-1", TokenKind::Refresh, vec![]).unwrap();

        assert!(iss.verify(&token, TokenKind::Media).is_err());
    }

    #[test]
    fn a_token_from_another_secret_is_rejected() {
        let (token, _) = issuer().issue("user-1", TokenKind::Access, vec![]).unwrap();

        let other = Issuer::new(b"a-completely-different-secret-value-here");

        assert!(other.verify(&token, TokenKind::Access).is_err());
    }

    #[test]
    fn a_media_token_expires_sooner_than_an_access_token() {
        let iss = issuer();
        let (_, media_exp) = iss.issue("u", TokenKind::Media, vec![]).unwrap();
        let (_, access_exp) = iss.issue("u", TokenKind::Access, vec![]).unwrap();

        assert!(media_exp < access_exp);
    }
}
