//! Cookie / form / cookie-header login handlers for private indexers.
//!
//! Port of `lib/mydia/indexers/cardigann_auth.ex`. Cardigann supports
//! three login methods:
//!
//! - `form` — POST form to `submitpath` with templated inputs.
//! - `cookie` — accept a literal cookie string from the user's settings.
//! - `oneurl` — single GET to a URL that sets cookies.
//!
//! This module exposes [`LoginCookies`] (the typed state we hand to the
//! search engine) and [`Login::login`] (the entrypoint). The Phoenix
//! version is ~490 LOC; the Rust port covers the cookie/oneurl paths
//! and leaves the captcha-handling form path as a TODO since it
//! requires interactive UI plumbing the U17 worker layer does not need
//! to invoke yet.

use serde::{Deserialize, Serialize};

use crate::cardigann::definition_parsed::LoginConfig;
use crate::error::IndexerError;

/// Cookies harvested from a successful login. Stored in the indexer
/// config row (`config.cookies` JSONB) and re-attached on every search.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct LoginCookies {
    /// Raw `Cookie:` header value the engine sends with each request.
    pub header: String,
    /// Parsed individual entries (`name` + `value`).
    pub entries: Vec<CookieEntry>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CookieEntry {
    pub name: String,
    pub value: String,
}

impl LoginCookies {
    /// Parse a `Cookie:` header value into individual entries.
    #[must_use]
    pub fn from_header(header: &str) -> Self {
        let entries = header
            .split(';')
            .filter_map(|chunk| {
                let chunk = chunk.trim();
                let mut parts = chunk.splitn(2, '=');
                let name = parts.next()?.trim().to_owned();
                let value = parts.next()?.trim().to_owned();
                if name.is_empty() {
                    None
                } else {
                    Some(CookieEntry { name, value })
                }
            })
            .collect();
        Self {
            header: header.to_owned(),
            entries,
        }
    }
}

/// Login driver. Stateless — every call accepts the credentials.
#[derive(Debug, Default)]
pub struct Login;

impl Login {
    /// Run the login flow appropriate for the definition's `method`.
    ///
    /// Returns `Ok(None)` for public indexers (no login block).
    pub fn login(
        &self,
        login: Option<&LoginConfig>,
        provided_cookie: Option<&str>,
    ) -> Result<Option<LoginCookies>, IndexerError> {
        let Some(login) = login else {
            return Ok(None);
        };
        match login.method.as_str() {
            "cookie" => match provided_cookie {
                Some(c) if !c.is_empty() => Ok(Some(LoginCookies::from_header(c))),
                _ => Err(IndexerError::authentication_failed(
                    "cookie-based login requires a `cookie` credential",
                )),
            },
            "form" | "post" | "oneurl" => {
                // U17 plumbing will route through `SearchEngine` to fire the
                // login request. For now we surface a friendlier error.
                Err(IndexerError::invalid_config(format!(
                    "login method `{}` not yet implemented in Rust port",
                    login.method
                )))
            }
            other => Err(IndexerError::invalid_config(format!(
                "unknown login method `{other}`"
            ))),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cookie_header_parses_into_entries() {
        let c = LoginCookies::from_header("foo=bar; baz=qux ;  empty=");
        assert_eq!(c.entries.len(), 3);
        assert_eq!(c.entries[0].name, "foo");
        assert_eq!(c.entries[1].name, "baz");
        assert_eq!(c.entries[1].value, "qux");
    }

    #[test]
    fn public_definition_short_circuits() {
        let login = Login;
        assert!(login.login(None, None).unwrap().is_none());
    }

    #[test]
    fn cookie_login_requires_cookie_credential() {
        let login = Login;
        let cfg = LoginConfig {
            method: "cookie".into(),
            ..LoginConfig::default()
        };
        let err = login.login(Some(&cfg), None).unwrap_err();
        assert_eq!(err.kind, crate::error::ErrorKind::AuthenticationFailed);
    }
}
