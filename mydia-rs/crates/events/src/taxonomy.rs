//! Event taxonomy.
//!
//! Port of:
//! - `lib/mydia/events.ex` (the constants the changeset validates against)
//! - `lib/mydia/events/event.ex` (`actor_type`, `severity_levels`)
//!
//! The Phoenix source treats `category` and `type` as bare strings
//! validated by regex (`^[a-z_]+$` and `^[a-z_]+\.[a-z_]+$`). The Rust
//! port mirrors that — the canonical category list lives here so call
//! sites can use typed enums where they want, but unknown values are
//! still accepted (forward-compat).

use serde::{Deserialize, Serialize};

/// Categories the Phoenix codebase emits. Order matches the source.
/// Use `as_str()` to get the wire value.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Category {
    Media,
    Downloads,
    Search,
    System,
    Library,
    Integrations,
}

impl Category {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Media => "media",
            Self::Downloads => "downloads",
            Self::Search => "search",
            Self::System => "system",
            Self::Library => "library",
            Self::Integrations => "integrations",
        }
    }
}

/// Actor kinds — who performed the action. Mirrors
/// `Mydia.Events.Event` `@actor_types`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ActorType {
    User,
    System,
    Job,
}

impl ActorType {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::User => "user",
            Self::System => "system",
            Self::Job => "job",
        }
    }

    /// Parse a string into [`ActorType`]. Returns `None` for unknown
    /// values so callers can decide whether to error or treat as
    /// `None` (which is itself a valid column value).
    #[must_use]
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "user" => Some(Self::User),
            "system" => Some(Self::System),
            "job" => Some(Self::Job),
            _ => None,
        }
    }
}

/// Severity levels. Default `Info`.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Severity {
    #[default]
    Info,
    Warning,
    Error,
}

impl Severity {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Info => "info",
            Self::Warning => "warning",
            Self::Error => "error",
        }
    }

    #[must_use]
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "info" => Some(Self::Info),
            "warning" => Some(Self::Warning),
            "error" => Some(Self::Error),
            _ => None,
        }
    }
}

/// Canonical event-type names that the Phoenix codebase emits.
/// These are not exhaustive of every value the DB might ever store —
/// the column is just a string — but every helper in
/// `lib/mydia/events.ex` produces one of these. Keep in sync with
/// `Mydia.Events.format_for_timeline/1`'s `case type` branches.
pub mod event_types {
    pub const MEDIA_ITEM_ADDED: &str = "media_item.added";
    pub const MEDIA_ITEM_UPDATED: &str = "media_item.updated";
    pub const MEDIA_ITEM_REMOVED: &str = "media_item.removed";
    pub const MEDIA_ITEM_MONITORING_CHANGED: &str = "media_item.monitoring_changed";
    pub const MEDIA_FILE_IMPORTED: &str = "media_file.imported";
    pub const MEDIA_ITEM_EPISODES_REFRESHED: &str = "media_item.episodes_refreshed";

    pub const DOWNLOAD_INITIATED: &str = "download.initiated";
    pub const DOWNLOAD_COMPLETED: &str = "download.completed";
    pub const DOWNLOAD_FAILED: &str = "download.failed";
    pub const DOWNLOAD_CANCELLED: &str = "download.cancelled";
    pub const DOWNLOAD_PAUSED: &str = "download.paused";
    pub const DOWNLOAD_RESUMED: &str = "download.resumed";
    pub const DOWNLOAD_CLEARED: &str = "download.cleared";

    pub const JOB_EXECUTED: &str = "job.executed";
    pub const JOB_FAILED: &str = "job.failed";

    pub const SEARCH_STARTED: &str = "search.started";
    pub const SEARCH_COMPLETED: &str = "search.completed";
    pub const SEARCH_NO_RESULTS: &str = "search.no_results";
    pub const SEARCH_FILTERED_OUT: &str = "search.filtered_out";
    pub const SEARCH_ERROR: &str = "search.error";
    pub const SEARCH_BACKOFF_APPLIED: &str = "search.backoff_applied";
    pub const SEARCH_BACKOFF_RESET: &str = "search.backoff_reset";
}

/// Input shape for `EventsContext::record`. Mirrors the `attrs` map
/// the Phoenix `create_event/1` accepts.
///
/// `metadata` is JSON because the Phoenix `:map` column accepts a
/// free-form payload. Call sites that want typed metadata should
/// build a struct, `serde_json::to_value` it, and put the result here.
#[derive(Debug, Clone)]
pub struct EventInput {
    pub category: String,
    pub event_type: String,
    pub actor_type: Option<ActorType>,
    pub actor_id: Option<String>,
    pub resource_type: Option<String>,
    pub resource_id: Option<String>,
    pub severity: Severity,
    pub metadata: serde_json::Map<String, serde_json::Value>,
}

impl EventInput {
    /// Build a minimal input. Convenience for call sites that want a
    /// builder pattern.
    #[must_use]
    pub fn new(category: impl Into<String>, event_type: impl Into<String>) -> Self {
        Self {
            category: category.into(),
            event_type: event_type.into(),
            actor_type: None,
            actor_id: None,
            resource_type: None,
            resource_id: None,
            severity: Severity::Info,
            metadata: serde_json::Map::new(),
        }
    }

    #[must_use]
    pub fn with_actor(mut self, actor_type: ActorType, actor_id: impl Into<String>) -> Self {
        self.actor_type = Some(actor_type);
        self.actor_id = Some(actor_id.into());
        self
    }

    #[must_use]
    pub fn with_resource(
        mut self,
        resource_type: impl Into<String>,
        resource_id: impl Into<String>,
    ) -> Self {
        self.resource_type = Some(resource_type.into());
        self.resource_id = Some(resource_id.into());
        self
    }

    #[must_use]
    pub fn with_severity(mut self, severity: Severity) -> Self {
        self.severity = severity;
        self
    }

    #[must_use]
    pub fn with_metadata(mut self, metadata: serde_json::Map<String, serde_json::Value>) -> Self {
        self.metadata = metadata;
        self
    }

    /// Validate the inputs match the Phoenix changeset rules. Useful
    /// at write sites that want to fail fast before hitting the DB.
    pub fn validate(&self) -> Result<(), TaxonomyError> {
        if !is_valid_category(&self.category) {
            return Err(TaxonomyError::InvalidCategory(self.category.clone()));
        }
        if !is_valid_event_type(&self.event_type) {
            return Err(TaxonomyError::InvalidEventType(self.event_type.clone()));
        }
        if self.actor_type.is_some() && self.actor_id.is_none() {
            return Err(TaxonomyError::ActorIdRequired);
        }
        Ok(())
    }
}

/// Phoenix regex: `^[a-z_]+$`.
#[must_use]
pub fn is_valid_category(s: &str) -> bool {
    !s.is_empty() && s.chars().all(|c| c.is_ascii_lowercase() || c == '_')
}

/// Phoenix regex: `^[a-z_]+\.[a-z_]+$`.
#[must_use]
pub fn is_valid_event_type(s: &str) -> bool {
    let mut parts = s.split('.');
    let head = parts.next();
    let tail = parts.next();
    let trailing = parts.next();
    match (head, tail, trailing) {
        (Some(h), Some(t), None) => is_valid_category(h) && is_valid_category(t),
        _ => false,
    }
}

/// Errors `EventInput::validate` returns.
#[derive(Debug, thiserror::Error)]
pub enum TaxonomyError {
    #[error("invalid category: {0}")]
    InvalidCategory(String),
    #[error("invalid event type: {0}")]
    InvalidEventType(String),
    #[error("actor_id is required when actor_type is set")]
    ActorIdRequired,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn category_round_trips_through_json() {
        let json = serde_json::to_string(&Category::Media).unwrap();
        assert_eq!(json, "\"media\"");
        let back: Category = serde_json::from_str(&json).unwrap();
        assert_eq!(back, Category::Media);
    }

    #[test]
    fn actor_type_parse_matches_phoenix_atoms() {
        assert_eq!(ActorType::parse("user"), Some(ActorType::User));
        assert_eq!(ActorType::parse("job"), Some(ActorType::Job));
        assert_eq!(ActorType::parse("admin"), None);
    }

    #[test]
    fn validates_category_format() {
        assert!(is_valid_category("media"));
        assert!(is_valid_category("media_player"));
        assert!(!is_valid_category("Media"));
        assert!(!is_valid_category("media-player"));
        assert!(!is_valid_category(""));
    }

    #[test]
    fn validates_event_type_format() {
        assert!(is_valid_event_type("media.added"));
        assert!(is_valid_event_type("media_player.added"));
        assert!(!is_valid_event_type("Media.Added"));
        assert!(!is_valid_event_type("media.added.extra"));
        assert!(!is_valid_event_type("noseparator"));
    }

    #[test]
    fn input_validates_actor_constraints() {
        let mut input = EventInput::new("media", "media_item.added");
        input.actor_type = Some(ActorType::User);
        // actor_id missing → error.
        assert!(input.validate().is_err());
        input.actor_id = Some("123".into());
        assert!(input.validate().is_ok());
    }

    #[test]
    fn input_validate_rejects_bad_category() {
        let input = EventInput::new("Media", "media_item.added");
        assert!(matches!(
            input.validate(),
            Err(TaxonomyError::InvalidCategory(_))
        ));
    }
}
