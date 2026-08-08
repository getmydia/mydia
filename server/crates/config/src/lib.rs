//! Layered configuration.
//!
//! Precedence, lowest to highest: built-in defaults, the YAML file,
//! environment variables, the database overlay written from the admin UI.
//! Every resolved key records which layer supplied it, because the admin UI
//! shows the source beside each field.

pub mod db_provider;

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use figment::providers::{Env, Format, Serialized, Yaml};
use figment::Figment;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LibraryPathSetting {
    pub path: PathBuf,
    /// One of "movies", "series" or "mixed". Validated when the rows are
    /// synced rather than here, so a typo names the offending path.
    pub library_type: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LibrarySettings {
    #[serde(default)]
    pub paths: Vec<LibraryPathSetting>,
    #[serde(default = "default_true")]
    pub scan_on_start: bool,
    #[serde(default = "default_scan_interval")]
    pub scan_interval_seconds: u64,
}

fn default_true() -> bool {
    true
}

fn default_scan_interval() -> u64 {
    6 * 60 * 60
}

impl Default for LibrarySettings {
    fn default() -> Self {
        Self {
            paths: Vec::new(),
            scan_on_start: default_true(),
            scan_interval_seconds: default_scan_interval(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    pub data_dir: PathBuf,
    pub bind_address: String,
    pub port: u16,
    pub metadata_relay_url: String,
    pub secret_key_base: String,
    #[serde(default)]
    pub library: LibrarySettings,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            data_dir: PathBuf::from("/var/lib/mydia-server"),
            bind_address: "0.0.0.0".to_string(),
            port: 4001,
            metadata_relay_url: "https://relay.mydia.dev".to_string(),
            secret_key_base: String::new(),
            library: LibrarySettings::default(),
        }
    }
}

/// Which layer supplied a value.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Source {
    Default,
    File,
    Environment,
    Database,
}

#[derive(Debug, thiserror::Error)]
pub enum ConfigError {
    #[error("configuration is not valid: {0}")]
    Extract(#[source] Box<figment::Error>),

    #[error("database setting `{key}` has an invalid value `{value}`")]
    InvalidOverlayValue { key: String, value: String },

    #[error("database setting `{0}` is not a supported configuration key")]
    UnknownOverlayKey(String),
}

pub struct Loaded {
    pub config: Config,
    sources: HashMap<String, Source>,
}

impl Loaded {
    pub fn source(&self, key: &str) -> Option<Source> {
        self.sources.get(key).copied()
    }

    /// Every key with its source, for the admin UI settings page.
    pub fn sources(&self) -> &HashMap<String, Source> {
        &self.sources
    }
}

#[derive(Default)]
pub struct Loader {
    yaml: Option<PathBuf>,
    env: bool,
    overlay: Vec<(String, String)>,
}

impl Loader {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_yaml(mut self, path: &Path) -> Self {
        self.yaml = Some(path.to_path_buf());
        self
    }

    pub fn with_env(mut self) -> Self {
        self.env = true;
        self
    }

    pub fn with_overlay(mut self, overlay: Vec<(String, String)>) -> Self {
        self.overlay = overlay;
        self
    }

    pub fn load(self) -> Result<Loaded, ConfigError> {
        let mut sources = HashMap::new();
        let mut figment = Figment::from(Serialized::defaults(Config::default()));

        for key in KNOWN_KEYS {
            sources.insert((*key).to_string(), Source::Default);
        }

        if let Some(path) = &self.yaml {
            let provider = Yaml::file(path);
            figment = figment.merge(provider);
            mark(
                &mut sources,
                &keys_in(&Figment::from(Yaml::file(path))),
                Source::File,
            );
        }

        if self.env {
            let provider = Env::prefixed("MYDIA_").split("__");
            figment = figment.merge(provider.clone());
            mark(
                &mut sources,
                &keys_in(&Figment::from(provider)),
                Source::Environment,
            );
        }

        let mut config = figment
            .extract()
            .map_err(|error| ConfigError::Extract(Box::new(error)))?;

        for (key, value) in &self.overlay {
            apply_overlay(&mut config, key, value)?;
            sources.insert(key.clone(), Source::Database);
        }

        Ok(Loaded { config, sources })
    }
}

const KNOWN_KEYS: &[&str] = &[
    "data_dir",
    "bind_address",
    "port",
    "metadata_relay_url",
    "secret_key_base",
    "library",
];

fn keys_in(figment: &Figment) -> Vec<String> {
    KNOWN_KEYS
        .iter()
        .filter(|key| figment.find_value(key).is_ok())
        .map(|key| (*key).to_string())
        .collect()
}

fn mark(sources: &mut HashMap<String, Source>, keys: &[String], source: Source) {
    for key in keys {
        sources.insert(key.clone(), source);
    }
}

/// Generates a fresh JWT signing key.
///
/// Called on first boot, when no `secret_key_base` has been configured by
/// any layer. The caller is responsible for persisting the result to the
/// database overlay so subsequent boots reuse it instead of invalidating
/// every issued token.
pub fn generate_secret_key_base() -> String {
    format!(
        "{}{}",
        uuid::Uuid::new_v4().simple(),
        uuid::Uuid::new_v4().simple()
    )
}

fn apply_overlay(config: &mut Config, key: &str, value: &str) -> Result<(), ConfigError> {
    match key {
        "data_dir" => config.data_dir = PathBuf::from(value),
        "bind_address" => config.bind_address = value.to_string(),
        "port" => {
            config.port = value
                .parse()
                .map_err(|_| ConfigError::InvalidOverlayValue {
                    key: key.to_string(),
                    value: value.to_string(),
                })?
        }
        "metadata_relay_url" => config.metadata_relay_url = value.to_string(),
        "secret_key_base" => config.secret_key_base = value.to_string(),
        // The library section is a list of structures, which the flat
        // key/value overlay table cannot express. Slice 7 gives the admin UI
        // its own table for paths.
        "library" => {
            return Err(ConfigError::InvalidOverlayValue {
                key: key.to_string(),
                value: value.to_string(),
            })
        }
        _ => return Err(ConfigError::UnknownOverlayKey(key.to_string())),
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{Loader, Source};

    #[test]
    fn defaults_apply_when_nothing_else_is_set() {
        let loaded = Loader::new().load().unwrap();

        assert_eq!(loaded.config.port, 4001);
        assert_eq!(loaded.source("port"), Some(Source::Default));
    }

    #[test]
    fn the_overlay_beats_everything() {
        let loaded = Loader::new()
            .with_overlay(vec![("port".to_string(), "9999".to_string())])
            .load()
            .unwrap();

        assert_eq!(loaded.config.port, 9999);
        assert_eq!(loaded.source("port"), Some(Source::Database));
    }

    #[test]
    fn yaml_beats_defaults() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.yaml");
        std::fs::write(&path, "port: 5005\n").unwrap();

        let loaded = Loader::new().with_yaml(&path).load().unwrap();

        assert_eq!(loaded.config.port, 5005);
        assert_eq!(loaded.source("port"), Some(Source::File));
    }

    #[test]
    fn the_overlay_beats_yaml() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.yaml");
        std::fs::write(&path, "port: 5005\n").unwrap();

        let loaded = Loader::new()
            .with_yaml(&path)
            .with_overlay(vec![("port".to_string(), "9999".to_string())])
            .load()
            .unwrap();

        assert_eq!(loaded.config.port, 9999);
        assert_eq!(loaded.source("port"), Some(Source::Database));
    }

    #[test]
    fn an_untouched_key_keeps_its_default_source() {
        let loaded = Loader::new()
            .with_overlay(vec![("port".to_string(), "9999".to_string())])
            .load()
            .unwrap();

        assert_eq!(loaded.source("metadata_relay_url"), Some(Source::Default));
    }

    #[test]
    fn a_malformed_value_is_an_error_not_a_silent_default() {
        let result = Loader::new()
            .with_overlay(vec![("port".to_string(), "not-a-number".to_string())])
            .load();

        assert!(result.is_err());
    }

    #[test]
    fn generated_secret_key_bases_are_long_and_not_reused() {
        let a = super::generate_secret_key_base();
        let b = super::generate_secret_key_base();

        assert!(a.len() >= 32);
        assert_ne!(a, b);
    }

    #[test]
    fn library_paths_come_from_yaml() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.yaml");
        std::fs::write(
            &path,
            "library:\n  paths:\n    - path: /media/movies\n      library_type: movies\n    - path: /media/tv\n      library_type: series\n",
        )
        .unwrap();

        let loaded = Loader::new().with_yaml(&path).load().unwrap();

        assert_eq!(loaded.config.library.paths.len(), 2);
        assert_eq!(loaded.config.library.paths[1].library_type, "series");
        assert_eq!(loaded.source("library"), Some(Source::File));
    }

    #[test]
    fn the_library_section_defaults_to_no_paths() {
        let loaded = Loader::new().load().unwrap();

        assert!(loaded.config.library.paths.is_empty());
        assert!(loaded.config.library.scan_on_start);
        assert_eq!(loaded.config.library.scan_interval_seconds, 6 * 60 * 60);
    }

    #[test]
    fn the_library_section_cannot_be_set_from_the_flat_overlay() {
        let result = Loader::new()
            .with_overlay(vec![("library".to_string(), "/media".to_string())])
            .load();

        assert!(
            result.is_err(),
            "a list of structures is not a settings row"
        );
    }
}
