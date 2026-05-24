//! Typed errors for the db crate.

/// The sea-orm error variant is boxed to keep `Result<_, DbError>` cheap;
/// `sea_orm::DbErr` is ~120 bytes.
#[derive(Debug, thiserror::Error)]
pub enum DbError {
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

impl From<sea_orm::DbErr> for DbError {
    fn from(err: sea_orm::DbErr) -> Self {
        Self::SeaOrm(Box::new(err))
    }
}
