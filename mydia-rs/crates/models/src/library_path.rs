//! Port of `Mydia.Settings.LibraryPath`
//! (`lib/mydia/settings/library_path.ex`).
//!
//! Phoenix table: `library_paths`. `category_paths` is a `:map`
//! column (JSONB on Postgres, JSON-text on SQLite); modeled as a
//! `JsonMap<HashMap<String, String>>` since the Phoenix usage is
//! `%{category => relative_path}`.

use std::collections::HashMap;

use mydia_rs_db::types::{DateTimeSecs, JsonMap, UuidText};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, sqlx::FromRow, Serialize, Deserialize)]
pub struct LibraryPath {
    pub id: UuidText,
    pub path: Option<String>,
    pub r#type: Option<String>,
    pub monitored: bool,
    pub scan_interval: i32,
    pub last_scan_at: Option<DateTimeSecs>,
    pub last_scan_status: Option<String>,
    pub last_scan_error: Option<String>,
    pub from_env: bool,
    pub disabled: bool,
    pub category_paths: JsonMap<HashMap<String, String>>,
    pub auto_organize: bool,
    pub auto_import: bool,
    pub write_nfo: bool,
    pub auto_rename: bool,
    pub quality_profile_id: Option<UuidText>,
    pub updated_by_id: Option<UuidText>,
    pub inserted_at: DateTimeSecs,
    pub updated_at: DateTimeSecs,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LibraryPathKind {
    Movies,
    Series,
    Mixed,
    Music,
    Books,
    Adult,
}

impl LibraryPathKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Movies => "movies",
            Self::Series => "series",
            Self::Mixed => "mixed",
            Self::Music => "music",
            Self::Books => "books",
            Self::Adult => "adult",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "movies" => Some(Self::Movies),
            "series" => Some(Self::Series),
            "mixed" => Some(Self::Mixed),
            "music" => Some(Self::Music),
            "books" => Some(Self::Books),
            "adult" => Some(Self::Adult),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ScanStatus {
    Success,
    Failed,
    InProgress,
}

impl ScanStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Success => "success",
            Self::Failed => "failed",
            Self::InProgress => "in_progress",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "success" => Some(Self::Success),
            "failed" => Some(Self::Failed),
            "in_progress" => Some(Self::InProgress),
            _ => None,
        }
    }
}

impl LibraryPath {
    pub fn kind(&self) -> Option<LibraryPathKind> {
        self.r#type.as_deref().and_then(LibraryPathKind::parse)
    }

    pub fn scan_status(&self) -> Option<ScanStatus> {
        self.last_scan_status.as_deref().and_then(ScanStatus::parse)
    }
}
