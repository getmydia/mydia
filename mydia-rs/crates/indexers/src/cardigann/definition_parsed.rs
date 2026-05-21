//! Parsed Cardigann v11 YAML definition.
//!
//! Port of `lib/mydia/indexers/cardigann_definition/parsed.ex`. The
//! YAML shape is large and idiosyncratic, so the inner sub-shapes are
//! kept as `serde_json::Value` until the caller needs them — the
//! struct only types the fields the search engine + result parser
//! consult directly.

use serde::{Deserialize, Serialize};

/// Compact representation of a single selector entry from the YAML.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Selector {
    /// CSS selector expression (or empty when only `text` is set).
    #[serde(default)]
    pub selector: String,
    /// Attribute to extract instead of the inner text.
    pub attribute: Option<String>,
    /// Selector for nodes to strip before extracting.
    pub remove: Option<String>,
    /// Case-rewriting table (`{"a[href*=foo]": "Movies/HD"}`).
    pub case: Option<serde_json::Value>,
    /// Post-processing filter chain (`{name, args}` shapes).
    #[serde(default)]
    pub filters: Vec<serde_json::Value>,
    /// Computed value template (`{{ .Result.title }} {{ .Result.size }}`).
    pub text: Option<String>,
    /// When true, missing fields don't fail the row.
    #[serde(default)]
    pub optional: bool,
    /// Walking pointer for repeated rows (`rows.after`).
    pub after: Option<i32>,
    /// Soft cap on rows yielded.
    pub count: Option<i32>,
}

/// One entry in `search.paths`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SearchPath {
    pub path: String,
    #[serde(default)]
    pub categories: Vec<serde_json::Value>,
    #[serde(default = "default_method")]
    pub method: String,
}

fn default_method() -> String {
    "get".into()
}

/// Normalized search-block payload.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct SearchConfig {
    pub paths: Vec<SearchPath>,
    #[serde(default)]
    pub inputs: serde_json::Value,
    pub headers: Option<serde_json::Value>,
    #[serde(default)]
    pub keywords_filters: Vec<serde_json::Value>,
    pub rows: Selector,
    /// Field-selector table. The Elixir code uses atom keys; here we
    /// keep them as snake_case strings (`title`, `download_url`, …).
    pub fields: std::collections::BTreeMap<String, Selector>,
}

/// Normalized login block (set for private indexers).
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct LoginConfig {
    pub method: String,
    pub path: Option<String>,
    pub submitpath: Option<String>,
    #[serde(default)]
    pub inputs: serde_json::Value,
    #[serde(default)]
    pub error: Vec<Selector>,
    pub test: Option<serde_json::Value>,
    #[serde(default)]
    pub cookies: Vec<String>,
    pub captcha: Option<serde_json::Value>,
}

/// Optional download-block configuration.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct DownloadConfig {
    #[serde(default)]
    pub selectors: Vec<Selector>,
    pub before: Option<serde_json::Value>,
    #[serde(default = "default_method")]
    pub method: String,
    pub infohash: Option<Selector>,
}

/// One setting (toggle, dropdown, …) the user must configure.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Setting {
    pub name: String,
    pub r#type: String,
    #[serde(default)]
    pub label: String,
    pub default: Option<serde_json::Value>,
    pub options: Option<serde_json::Value>,
}

/// Capabilities block (`caps`).
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Capabilities {
    #[serde(default)]
    pub modes: serde_json::Value,
    #[serde(default)]
    pub categories: serde_json::Value,
    /// `[%{id, cat, desc}, ...]`.
    #[serde(default)]
    pub categorymappings: Vec<serde_json::Value>,
}

/// Full parsed definition.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ParsedDefinition {
    pub id: String,
    pub name: String,
    pub description: String,
    pub language: String,
    pub r#type: String,
    pub encoding: String,
    pub links: Vec<String>,
    pub capabilities: Capabilities,
    pub search: SearchConfig,
    pub login: Option<LoginConfig>,
    pub download: Option<DownloadConfig>,
    #[serde(default)]
    pub settings: Vec<Setting>,
    pub request_delay: Option<f64>,
    #[serde(default)]
    pub follow_redirect: bool,
    #[serde(default)]
    pub test_link_torrent: bool,
    #[serde(default)]
    pub certificates: Vec<String>,
    #[serde(default)]
    pub replaces: Vec<String>,
}
