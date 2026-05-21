//! Tracing subscriber installation matching the boot-time logging shape.
//!
//! - `LogFormat::Text` registers a human-friendly compact formatter
//!   suitable for `./dev rs run`.
//! - `LogFormat::Json` registers a structured single-line JSON formatter
//!   suitable for production log shipping.
//!
//! Level filtering reads `RUST_LOG` if set (lets operators target
//! per-module verbosity ad hoc) and falls back to the configured level.

use tracing_subscriber::fmt;
use tracing_subscriber::layer::SubscriberExt;
use tracing_subscriber::util::SubscriberInitExt;
use tracing_subscriber::EnvFilter;

use crate::schema::{LogFormat, LoggingConfig};

/// Errors surfaced from [`install`].
#[derive(Debug, thiserror::Error)]
pub enum TracingError {
    #[error("a tracing subscriber is already installed for this process")]
    AlreadyInstalled,
}

/// Install the global tracing subscriber once. Returns an error if a
/// subscriber is already installed (common in tests; ignore there).
pub fn install(logging: &LoggingConfig) -> Result<(), TracingError> {
    let env_filter = EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| EnvFilter::new(logging.level.as_tracing_filter()));

    let registry = tracing_subscriber::registry().with(env_filter);

    let install_result = match logging.format {
        LogFormat::Text => registry.with(fmt::layer().compact()).try_init(),
        LogFormat::Json => registry
            .with(fmt::layer().json().with_current_span(true))
            .try_init(),
    };

    install_result.map_err(|_| TracingError::AlreadyInstalled)
}
