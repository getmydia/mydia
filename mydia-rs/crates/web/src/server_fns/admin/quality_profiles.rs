//! Quality-profile management.
//!
//! Phoenix counterpart: `MydiaWeb.AdminQualityProfilesLive` plus
//! `Mydia.Settings.QualityProfile`. A quality profile is named bundle
//! of cutoff rules ("which release qualities does mydia accept and
//! in what priority order"). The Phoenix schema models this as a
//! single `quality_profiles` row with:
//!
//! - `name` (unique, required)
//! - `description` (optional free text)
//! - `qualities` — a `StringListType` (JSON list of resolution strings,
//!   ordered: first item is highest priority). At least one is
//!   required.
//! - `upgrades_allowed` (boolean default true)
//! - `quality_standards` — a `JsonAtomMapType` of further filters
//!   (preferred codecs, bitrate ranges, etc.). U28 follow-up ports
//!   the core fields (name/description/qualities); the full
//!   quality-standards editor is a deeper follow-up.
//!
//! Validation rules ported here (matching the Phoenix changeset):
//!
//! - `name` non-blank, unique per row.
//! - `qualities` non-empty, all values must be in the known resolution
//!   set, no duplicates within a single profile.
//!
//! Phoenix rules deferred (because they live entirely in the
//! `quality_standards` JSON map which U28-followup doesn't expose
//! yet):
//!
//! - `preferred_video_codecs`, `preferred_audio_codecs`, etc. — full
//!   enum membership checks. These would surface in the
//!   quality-standards tab; the Rust page exposes only the qualities
//!   list for now and ignores the standards map (it round-trips as
//!   stored, no edits).

use dioxus::fullstack::ServerFnError;
use dioxus::prelude::*;
use serde::{Deserialize, Serialize};

/// The known resolution values a quality cutoff can take, ordered
/// low-to-high. Mirrors `Mydia.Settings.QualityProfile.@valid_resolutions`.
pub const VALID_RESOLUTIONS: &[&str] = &["360p", "480p", "576p", "720p", "1080p", "2160p", "4320p"];

/// Row shape for the list view (no nested data).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct QualityProfileRow {
    pub id: String,
    pub name: String,
    /// Count of cutoff items configured on this profile. Sourced from
    /// the JSON `qualities` column length so the list view shows the
    /// shape without parsing the JSON twice.
    pub cutoff_count: i64,
    pub inserted_at: Option<String>,
}

/// Full detail row for the edit modal.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
pub struct QualityProfileDetail {
    pub id: String,
    pub name: String,
    pub description: Option<String>,
    /// Ordered list of resolution strings. First item is highest
    /// priority.
    pub qualities: Vec<String>,
    pub inserted_at: Option<String>,
    pub updated_at: Option<String>,
}

/// Wire payload for create.
#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq, Eq)]
pub struct NewQualityProfile {
    pub name: String,
    #[serde(default)]
    pub description: Option<String>,
    pub qualities: Vec<String>,
}

/// Wire payload for update.
#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq, Eq)]
pub struct UpdateQualityProfile {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub description: Option<String>,
    pub qualities: Vec<String>,
}

#[get("/api/admin/quality_profiles")]
pub async fn list_quality_profiles() -> Result<Vec<QualityProfileRow>, ServerFnError> {
    server::list().await
}

#[post("/api/admin/quality_profiles/get")]
pub async fn get_quality_profile(id: String) -> Result<QualityProfileDetail, ServerFnError> {
    server::get(id).await
}

#[post("/api/admin/quality_profiles")]
pub async fn create_quality_profile(
    payload: NewQualityProfile,
) -> Result<QualityProfileDetail, ServerFnError> {
    server::create(payload).await
}

#[post("/api/admin/quality_profiles/update")]
pub async fn update_quality_profile(
    payload: UpdateQualityProfile,
) -> Result<QualityProfileDetail, ServerFnError> {
    server::update(payload).await
}

#[post("/api/admin/quality_profiles/delete")]
pub async fn delete_quality_profile(id: String) -> Result<(), ServerFnError> {
    server::delete(id).await
}

// ---------- Pure validation (compiled into both server + wasm builds) ----------

/// Validation outcome for a profile payload. Returned as a sentinel
/// when the input violates one of the changeset rules; the page
/// renders each error near the offending field.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ValidationError {
    /// `name` was blank or whitespace-only.
    BlankName,
    /// `qualities` was empty.
    EmptyQualities,
    /// A quality value isn't in [`VALID_RESOLUTIONS`].
    UnknownResolution(String),
    /// `qualities` contained the same resolution more than once.
    DuplicateResolution(String),
}

impl std::fmt::Display for ValidationError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::BlankName => f.write_str("Name is required"),
            Self::EmptyQualities => f.write_str("At least one cutoff item is required"),
            Self::UnknownResolution(res) => write!(
                f,
                "Resolution {res:?} is not a known value (allowed: {})",
                VALID_RESOLUTIONS.join(", ")
            ),
            Self::DuplicateResolution(res) => {
                write!(f, "Resolution {res:?} appears more than once")
            }
        }
    }
}

/// Validate a profile payload — both create and update share these
/// rules. Returns the first failure encountered in a deterministic
/// order so the surfaced error stays stable between renders.
#[must_use]
pub fn validate_profile(name: &str, qualities: &[String]) -> Option<ValidationError> {
    if name.trim().is_empty() {
        return Some(ValidationError::BlankName);
    }
    if qualities.is_empty() {
        return Some(ValidationError::EmptyQualities);
    }
    let mut seen: Vec<&str> = Vec::with_capacity(qualities.len());
    for q in qualities {
        if !VALID_RESOLUTIONS.contains(&q.as_str()) {
            return Some(ValidationError::UnknownResolution(q.clone()));
        }
        if seen.contains(&q.as_str()) {
            return Some(ValidationError::DuplicateResolution(q.clone()));
        }
        seen.push(q.as_str());
    }
    None
}

#[cfg(feature = "server")]
mod server {
    use super::{
        validate_profile, NewQualityProfile, QualityProfileDetail, QualityProfileRow,
        UpdateQualityProfile,
    };
    use crate::server_fns::auth::require_admin_user_id;
    use crate::server_state::WebState;
    use dioxus::fullstack::FullstackContext;
    use dioxus::fullstack::ServerFnError;
    use mydia_rs_db::types::{DateTimeSecs, UuidText};
    use mydia_rs_db::{insert_active_model, DatabaseConnection};
    use mydia_rs_entities::quality_profiles;
    use sea_orm::entity::prelude::*;
    use sea_orm::query::QueryOrder;
    use sea_orm::sea_query::{Expr, ExprTrait};
    use sea_orm::Set;

    async fn state() -> Result<WebState, ServerFnError> {
        let ctx = FullstackContext::current()
            .ok_or_else(|| ServerFnError::new("no fullstack context".to_owned()))?;
        ctx.extension::<WebState>()
            .ok_or_else(|| ServerFnError::new("WebState axum extension missing".to_owned()))
    }

    fn parse_uuid(s: &str) -> Option<UuidText> {
        uuid::Uuid::parse_str(s).ok().map(UuidText::from)
    }

    /// Decode a JSON `qualities` column to a Vec of strings. Tolerates
    /// empty strings and `[]`. Anything else falls back to an
    /// empty list rather than failing the read — older rows with
    /// malformed JSON shouldn't crash the admin page.
    fn decode_qualities(raw: &str) -> Vec<String> {
        if raw.trim().is_empty() {
            return Vec::new();
        }
        serde_json::from_str::<Vec<String>>(raw).unwrap_or_default()
    }

    fn encode_qualities(qualities: &[String]) -> String {
        serde_json::to_string(qualities).unwrap_or_else(|_| "[]".to_owned())
    }

    pub(super) async fn list() -> Result<Vec<QualityProfileRow>, ServerFnError> {
        let _ = require_admin_user_id().await?;
        let st = state().await?;
        let rows = quality_profiles::Entity::find()
            .order_by_asc(quality_profiles::Column::InsertedAt)
            .order_by_asc(quality_profiles::Column::Name)
            .all(&st.db)
            .await
            .map_err(|err| ServerFnError::new(format!("query quality_profiles: {err}")))?;
        Ok(rows
            .into_iter()
            .map(|m| {
                let count = decode_qualities(&m.qualities).len() as i64;
                QualityProfileRow {
                    id: m.id.to_string(),
                    name: m.name,
                    cutoff_count: count,
                    inserted_at: Some(m.inserted_at.0.to_rfc3339()),
                }
            })
            .collect())
    }

    pub(super) async fn get(id: String) -> Result<QualityProfileDetail, ServerFnError> {
        let _ = require_admin_user_id().await?;
        let st = state().await?;
        let Some(wrapper) = parse_uuid(&id) else {
            return Err(ServerFnError::new("quality profile not found"));
        };
        let backend = st.db.get_database_backend();
        let row = quality_profiles::Entity::find()
            .filter(Expr::col(quality_profiles::Column::Id).eq(wrapper.into_simple_expr(backend)))
            .one(&st.db)
            .await
            .map_err(|err| ServerFnError::new(format!("query quality_profile: {err}")))?;
        let Some(m) = row else {
            return Err(ServerFnError::new("quality profile not found"));
        };
        Ok(QualityProfileDetail {
            id: m.id.to_string(),
            name: m.name,
            description: m.description,
            qualities: decode_qualities(&m.qualities),
            inserted_at: Some(m.inserted_at.0.to_rfc3339()),
            updated_at: Some(m.updated_at.0.to_rfc3339()),
        })
    }

    async fn name_taken(
        db: &DatabaseConnection,
        name: &str,
        except_id: Option<&str>,
    ) -> Result<bool, ServerFnError> {
        let mut q = quality_profiles::Entity::find()
            .filter(quality_profiles::Column::Name.eq(name.to_owned()));
        if let Some(id) = except_id {
            if let Some(wrapper) = parse_uuid(id) {
                let backend = db.get_database_backend();
                q = q.filter(
                    Expr::col(quality_profiles::Column::Id).ne(wrapper.into_simple_expr(backend)),
                );
            }
        }
        let count = q
            .count(db)
            .await
            .map_err(|err| ServerFnError::new(format!("name uniqueness: {err}")))?;
        Ok(count > 0)
    }

    pub(super) async fn create(
        payload: NewQualityProfile,
    ) -> Result<QualityProfileDetail, ServerFnError> {
        let _ = require_admin_user_id().await?;
        let name = payload.name.trim().to_owned();
        if let Some(err) = validate_profile(&name, &payload.qualities) {
            return Err(ServerFnError::new(err.to_string()));
        }
        let st = state().await?;
        if name_taken(&st.db, &name, None).await? {
            return Err(ServerFnError::new(format!(
                "A quality profile named {name:?} already exists"
            )));
        }

        let id_uuid = uuid::Uuid::new_v4();
        let id_str = id_uuid.to_string();
        let id = UuidText::from(id_uuid);
        let now = DateTimeSecs::from(chrono::Utc::now());
        let qualities_json = encode_qualities(&payload.qualities);
        let description = payload
            .description
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_owned);

        let am = quality_profiles::ActiveModel {
            id: Set(id),
            name: Set(name.clone()),
            upgrades_allowed: Set(Some(true)),
            upgrade_until_quality: Set(None),
            qualities: Set(qualities_json),
            inserted_at: Set(now),
            updated_at: Set(now),
            description: Set(description.clone()),
            is_system: Set(Some(false)),
            version: Set(None),
            source_url: Set(None),
            last_synced_at: Set(None),
            quality_standards: Set(None),
            metadata_preferences: Set(None),
            customizations: Set(None),
        };
        insert_active_model(am, &st.db)
            .await
            .map_err(|err| ServerFnError::new(format!("insert quality_profile: {err}")))?;

        Ok(QualityProfileDetail {
            id: id_str,
            name,
            description,
            qualities: payload.qualities,
            inserted_at: Some(now.0.to_rfc3339()),
            updated_at: Some(now.0.to_rfc3339()),
        })
    }

    pub(super) async fn update(
        payload: UpdateQualityProfile,
    ) -> Result<QualityProfileDetail, ServerFnError> {
        let _ = require_admin_user_id().await?;
        let name = payload.name.trim().to_owned();
        if let Some(err) = validate_profile(&name, &payload.qualities) {
            return Err(ServerFnError::new(err.to_string()));
        }
        let st = state().await?;
        if name_taken(&st.db, &name, Some(&payload.id)).await? {
            return Err(ServerFnError::new(format!(
                "A quality profile named {name:?} already exists"
            )));
        }
        let Some(wrapper) = parse_uuid(&payload.id) else {
            return Err(ServerFnError::new("quality profile not found"));
        };
        let backend = st.db.get_database_backend();
        let now = DateTimeSecs::from(chrono::Utc::now());
        let qualities_json = encode_qualities(&payload.qualities);
        let description = payload
            .description
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_owned);

        let res = quality_profiles::Entity::update_many()
            .col_expr(quality_profiles::Column::Name, Expr::value(name.clone()))
            .col_expr(
                quality_profiles::Column::Description,
                Expr::value(description.clone()),
            )
            .col_expr(
                quality_profiles::Column::Qualities,
                Expr::value(qualities_json),
            )
            .col_expr(
                quality_profiles::Column::UpdatedAt,
                now.into_simple_expr(backend),
            )
            .filter(Expr::col(quality_profiles::Column::Id).eq(wrapper.into_simple_expr(backend)))
            .exec(&st.db)
            .await
            .map_err(|err| ServerFnError::new(format!("update quality_profile: {err}")))?;
        if res.rows_affected == 0 {
            return Err(ServerFnError::new("quality profile not found"));
        }

        get(payload.id).await
    }

    pub(super) async fn delete(id: String) -> Result<(), ServerFnError> {
        let _ = require_admin_user_id().await?;
        let st = state().await?;
        let Some(wrapper) = parse_uuid(&id) else {
            return Err(ServerFnError::new("quality profile not found"));
        };
        let backend = st.db.get_database_backend();
        let res = quality_profiles::Entity::delete_many()
            .filter(Expr::col(quality_profiles::Column::Id).eq(wrapper.into_simple_expr(backend)))
            .exec(&st.db)
            .await
            .map_err(|err| ServerFnError::new(format!("delete quality_profile: {err}")))?;
        if res.rows_affected == 0 {
            return Err(ServerFnError::new("quality profile not found"));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validate_rejects_blank_name() {
        assert_eq!(
            validate_profile("   ", &["1080p".to_owned()]),
            Some(ValidationError::BlankName)
        );
    }

    #[test]
    fn validate_rejects_empty_qualities() {
        assert_eq!(
            validate_profile("Ultra", &[]),
            Some(ValidationError::EmptyQualities)
        );
    }

    #[test]
    fn validate_rejects_unknown_resolution() {
        let qs = vec!["1080p".to_owned(), "9999p".to_owned()];
        assert_eq!(
            validate_profile("Ultra", &qs),
            Some(ValidationError::UnknownResolution("9999p".to_owned()))
        );
    }

    #[test]
    fn validate_rejects_duplicate_resolution() {
        let qs = vec!["1080p".to_owned(), "1080p".to_owned()];
        assert_eq!(
            validate_profile("Ultra", &qs),
            Some(ValidationError::DuplicateResolution("1080p".to_owned()))
        );
    }

    #[test]
    fn validate_accepts_canonical_payload() {
        let qs = vec!["2160p".to_owned(), "1080p".to_owned(), "720p".to_owned()];
        assert_eq!(validate_profile("Ultra", &qs), None);
    }

    #[test]
    fn valid_resolutions_match_phoenix_set() {
        // Pin the Phoenix-side known-resolutions enum (see
        // `Mydia.Settings.QualityProfile.@valid_resolutions`). If the
        // canonical list changes, both halves move together.
        assert_eq!(
            VALID_RESOLUTIONS,
            &["360p", "480p", "576p", "720p", "1080p", "2160p", "4320p"]
        );
    }

    #[test]
    fn validation_error_messages_mention_field_context() {
        // The page renders these strings beside the offending input,
        // so the message has to stand alone (no "for field X" prefix
        // the caller needs to add).
        assert!(ValidationError::BlankName.to_string().contains("Name"));
        assert!(ValidationError::EmptyQualities
            .to_string()
            .contains("cutoff"));
        let err = ValidationError::UnknownResolution("9999p".to_owned()).to_string();
        assert!(err.contains("9999p"));
        assert!(err.contains("allowed"));
        let dup = ValidationError::DuplicateResolution("1080p".to_owned()).to_string();
        assert!(dup.contains("1080p"));
    }
}
