use async_graphql::SimpleObject;
use chrono::{DateTime, Utc};

#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "QualityProfile")]
pub struct QualityProfile {
    pub id: async_graphql::ID,
    pub name: String,
    pub upgrades_allowed: bool,
    pub upgrade_until_quality: Option<String>,
    pub qualities: String,
    pub description: Option<String>,
    pub is_system: bool,
    pub version: Option<i32>,
    pub source_url: Option<String>,
    pub last_synced_at: Option<DateTime<Utc>>,
    pub quality_standards: Option<String>,
    pub metadata_preferences: Option<String>,
    pub customizations: Option<String>,
    pub inserted_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

impl QualityProfile {
    pub fn from_row(row: &mydia_rs_entities::quality_profiles::Model) -> Option<Self> {
        Some(Self {
            id: async_graphql::ID(row.id.0.to_string()),
            name: row.name.clone(),
            upgrades_allowed: row.upgrades_allowed.unwrap_or(false),
            upgrade_until_quality: row.upgrade_until_quality.clone(),
            qualities: row.qualities.clone(),
            description: row.description.clone(),
            is_system: row.is_system.unwrap_or(false),
            version: row.version,
            source_url: row.source_url.clone(),
            last_synced_at: row.last_synced_at.as_ref().map(|t| t.0),
            quality_standards: row.quality_standards.clone(),
            metadata_preferences: row.metadata_preferences.clone(),
            customizations: row.customizations.clone(),
            inserted_at: row.inserted_at.0,
            updated_at: row.updated_at.0,
        })
    }
}
