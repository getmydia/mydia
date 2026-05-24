//! Library path — port of `lib/mydia_web/schema/common_types.ex:92-130`.
//!
//! Implements the Node interface (full implementation in U10.c). For
//! U10.a this is a plain `SimpleObject`; the `parent`, `children`,
//! `ancestors`, `is_playable` fields land alongside the Node enum.

use async_graphql::{Enum, SimpleObject};
use chrono::{DateTime, Utc};

use crate::node_id::{NodeId, NodeRef};

/// Mirrors the Absinthe `library_type` enum (`enum_types.ex:34-41`).
#[derive(Debug, Copy, Clone, PartialEq, Eq, Enum)]
#[graphql(name = "LibraryType")]
pub enum LibraryType {
    Movies,
    Series,
    Mixed,
    Music,
    Books,
    Adult,
}

impl LibraryType {
    /// Parse the string column value Phoenix writes.
    pub fn from_db(value: &str) -> Option<Self> {
        match value {
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

#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "LibraryPath")]
pub struct LibraryPath {
    /// Encoded `library:<uuid>` form.
    pub id: async_graphql::ID,
    pub path: String,
    #[graphql(name = "type")]
    pub type_: LibraryType,
    pub monitored: bool,
    pub scan_interval: Option<i32>,
    pub last_scan_at: Option<DateTime<Utc>>,
    pub auto_organize: bool,
    pub auto_import: bool,
    pub write_nfo: bool,
    pub auto_rename: bool,
}

impl LibraryPath {
    pub fn from_row(row: &mydia_rs_entities::library_paths::Model) -> Option<Self> {
        let type_ = LibraryType::from_db(&row.r#type)?;
        Some(Self {
            id: NodeId::LibraryPath(NodeRef::Str(row.id.0.to_string()))
                .encode()
                .into(),
            path: row.path.clone(),
            type_,
            monitored: row.monitored.unwrap_or(false),
            scan_interval: row.scan_interval,
            last_scan_at: row.last_scan_at.as_ref().map(|t| t.0),
            auto_organize: row.auto_organize.unwrap_or(false),
            auto_import: row.auto_import.unwrap_or(false),
            write_nfo: row.write_nfo,
            auto_rename: row.auto_rename.unwrap_or(false),
        })
    }
}
