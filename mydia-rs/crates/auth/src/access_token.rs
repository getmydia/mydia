//! User-facing access tokens — the JWT the `login` mutation hands back.
//!
//! Phoenix issues these via `Mydia.Auth.Guardian.create_token/1` with
//! `token_type: :access` (see `lib/mydia/auth/guardian.ex:42-43`).
//! Guardian translates that into a JWT claim `typ: "access"` and the
//! subject is `to_string(user.id)` (the UUID). The signing algorithm
//! defaults to HS512 with the configured `secret_key`. This module
//! mirrors that shape so a token mydia-rs issues verifies against
//! Phoenix and vice-versa during the parallel window.
//!
//! Kept separate from [`crate::media_token`] so the `typ` distinction
//! is explicit — a Guardian token of one type does not validate as the
//! other.

use std::time::Duration;

use chrono::Utc;
use jsonwebtoken::{decode, encode, Algorithm, DecodingKey, EncodingKey, Header, Validation};
use serde::{Deserialize, Serialize};
use thiserror::Error;

/// JWT claims for a user access token. Only the fields the player
/// (and Phoenix itself) actually reads.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AccessTokenClaims {
    /// Stringified UUID of the user.
    pub sub: String,
    /// Guardian's token type marker.
    pub typ: String,
    pub iat: i64,
    pub exp: i64,
}

impl AccessTokenClaims {
    pub fn user_id(&self) -> &str {
        &self.sub
    }
}

#[derive(Debug, Error)]
pub enum AccessTokenError {
    #[error("token expired")]
    Expired,
    #[error("token type mismatch (expected 'access', got '{0}')")]
    WrongType(String),
    #[error("token invalid: {0}")]
    Invalid(String),
    #[error("internal: {0}")]
    Internal(String),
}

#[derive(Clone)]
pub struct AccessTokenSigner {
    encoding_key: EncodingKey,
    decoding_key: DecodingKey,
    leeway_secs: u64,
}

impl AccessTokenSigner {
    pub fn new(secret: &str, leeway_secs: u64) -> Self {
        Self {
            encoding_key: EncodingKey::from_secret(secret.as_bytes()),
            decoding_key: DecodingKey::from_secret(secret.as_bytes()),
            leeway_secs,
        }
    }

    /// Issue an access token for the given user, valid for `ttl`.
    /// Returns the encoded JWT string and its `(iat, exp)` pair so the
    /// caller can surface `expires_in` to the GraphQL response.
    pub fn issue(&self, user_id: &str, ttl: Duration) -> Result<IssuedToken, AccessTokenError> {
        let now = Utc::now().timestamp();
        let exp = now + ttl.as_secs() as i64;
        let claims = AccessTokenClaims {
            sub: user_id.to_owned(),
            typ: "access".into(),
            iat: now,
            exp,
        };
        let token = encode(&Header::new(Algorithm::HS512), &claims, &self.encoding_key)
            .map_err(|err| AccessTokenError::Internal(err.to_string()))?;
        Ok(IssuedToken {
            token,
            iat: now,
            exp,
        })
    }

    /// Verify a JWT and return its claims. Returns
    /// [`AccessTokenError::WrongType`] when the token's `typ` is not
    /// `"access"` (for example, a media-access token).
    pub fn verify(&self, token: &str) -> Result<AccessTokenClaims, AccessTokenError> {
        let mut validation = Validation::new(Algorithm::HS512);
        validation.leeway = self.leeway_secs;
        validation.required_spec_claims.clear();
        validation.required_spec_claims.insert("exp".into());
        match decode::<AccessTokenClaims>(token, &self.decoding_key, &validation) {
            Ok(data) => {
                if data.claims.typ != "access" {
                    return Err(AccessTokenError::WrongType(data.claims.typ));
                }
                Ok(data.claims)
            }
            Err(err) => {
                use jsonwebtoken::errors::ErrorKind;
                match err.kind() {
                    ErrorKind::ExpiredSignature => Err(AccessTokenError::Expired),
                    _ => Err(AccessTokenError::Invalid(err.to_string())),
                }
            }
        }
    }
}

/// Result of [`AccessTokenSigner::issue`]. Exposes the timestamps the
/// caller needs to surface `expires_in`.
#[derive(Debug, Clone)]
pub struct IssuedToken {
    pub token: String,
    pub iat: i64,
    pub exp: i64,
}

impl IssuedToken {
    pub fn expires_in_secs(&self) -> i64 {
        self.exp - self.iat
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn issue_then_verify_round_trips() {
        let signer = AccessTokenSigner::new("secret-key", 5);
        let issued = signer
            .issue(
                "00000000-0000-0000-0000-000000000001",
                Duration::from_secs(3600),
            )
            .unwrap();
        let claims = signer.verify(&issued.token).unwrap();
        assert_eq!(claims.user_id(), "00000000-0000-0000-0000-000000000001");
        assert_eq!(claims.typ, "access");
        assert_eq!(issued.expires_in_secs(), 3600);
    }

    #[test]
    fn verify_rejects_wrong_type() {
        let signer = AccessTokenSigner::new("secret-key", 0);
        let issued = signer.issue("u", Duration::from_secs(60)).unwrap();
        // Mutate the typ by re-issuing with a different signer instance
        // shouldn't help — instead, just confirm a manually crafted
        // wrong-type token surfaces WrongType. We piggyback on the
        // existing media-token claims shape via raw encoding.
        use jsonwebtoken::{encode as raw_encode, Header as RawHeader};
        #[derive(Serialize)]
        struct Foreign {
            sub: String,
            typ: String,
            iat: i64,
            exp: i64,
        }
        let key = EncodingKey::from_secret(b"secret-key");
        let foreign = raw_encode(
            &RawHeader::new(Algorithm::HS512),
            &Foreign {
                sub: "u".into(),
                typ: "media_access".into(),
                iat: 0,
                exp: i64::MAX,
            },
            &key,
        )
        .unwrap();
        let err = signer.verify(&foreign).unwrap_err();
        assert!(matches!(err, AccessTokenError::WrongType(_)));
        let _ = issued;
    }
}
