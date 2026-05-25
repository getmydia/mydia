//! Setting types — matches the Dioxus `ConfigSource` pattern from
//! `crates/web/src/components/admin/config_form.rs`.

use async_graphql::{Enum, SimpleObject};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Enum)]
#[graphql(name = "ConfigSource")]
pub enum ConfigSource {
    #[graphql(name = "default")]
    Default,
    #[graphql(name = "env")]
    Env,
    #[graphql(name = "database")]
    Database,
}

impl ConfigSource {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Default => "default",
            Self::Env => "env",
            Self::Database => "database",
        }
    }
}

#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "SettingRow")]
pub struct SettingRow {
    pub key: String,
    pub category: String,
    pub label: String,
    pub kind: String,
    pub value: String,
    pub source: ConfigSource,
    pub description: Option<String>,
    pub placeholder: Option<String>,
}
