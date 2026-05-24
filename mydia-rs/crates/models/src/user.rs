//! Port of `Mydia.Accounts.User` (`lib/mydia/accounts/user.ex`).
//!
//! Phoenix table: `users`. Primary key is a UUID stored as TEXT on
//! `SQLite` (`:binary_id_type = :string`) and `uuid` on Postgres. The
//! `password` / `password_confirmation` virtual fields exist only on
//! the Ecto changeset side and are intentionally not modelled here.

use mydia_rs_db::types::{DateTimeSecs, UuidText};
use serde::{Deserialize, Serialize};

/// Row from `users`. `role` is stored as TEXT; use [`UserRole::parse`]
/// to recover a typed value at the application layer.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct User {
    pub id: UuidText,
    pub username: Option<String>,
    pub email: Option<String>,
    pub password_hash: Option<String>,
    pub oidc_sub: Option<String>,
    pub oidc_issuer: Option<String>,
    pub role: String,
    pub display_name: Option<String>,
    pub avatar_url: Option<String>,
    pub last_login_at: Option<DateTimeSecs>,
    pub inserted_at: DateTimeSecs,
    pub updated_at: DateTimeSecs,
}

/// Typed role mirror of the `users.role` column.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum UserRole {
    Admin,
    User,
    Readonly,
    Guest,
}

impl UserRole {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Admin => "admin",
            Self::User => "user",
            Self::Readonly => "readonly",
            Self::Guest => "guest",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "admin" => Some(Self::Admin),
            "user" => Some(Self::User),
            "readonly" => Some(Self::Readonly),
            "guest" => Some(Self::Guest),
            _ => None,
        }
    }
}

impl User {
    /// Convenience accessor that parses `self.role` into [`UserRole`].
    /// Returns `None` if the DB holds a value outside the known set.
    pub fn role(&self) -> Option<UserRole> {
        UserRole::parse(&self.role)
    }
}
