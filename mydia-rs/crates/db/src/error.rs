//! Typed errors for the db crate.

/// The sqlx error variant is boxed to keep `Result<_, DbError>` cheap;
/// `sqlx::Error` is ~120 bytes.
#[derive(Debug, thiserror::Error)]
pub enum DbError {
    #[error("database error: {0}")]
    Sqlx(Box<sqlx::Error>),

    #[error("database error: {0}")]
    SeaOrm(Box<sea_orm::DbErr>),

    #[error("configured database driver is not compiled into this binary: {0}")]
    DriverNotCompiled(&'static str),

    #[error("database.{kind} = {required} but database.{kind} setting is missing or empty")]
    Misconfigured {
        kind: &'static str,
        required: &'static str,
    },

    #[error("schema check failed: {0}")]
    SchemaCheck(String),
}

impl From<sqlx::Error> for DbError {
    fn from(err: sqlx::Error) -> Self {
        Self::Sqlx(Box::new(err))
    }
}

impl From<sea_orm::DbErr> for DbError {
    fn from(err: sea_orm::DbErr) -> Self {
        Self::SeaOrm(Box::new(err))
    }
}
