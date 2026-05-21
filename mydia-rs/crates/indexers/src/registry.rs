//! Registry of configured indexer adapters.
//!
//! Port of `lib/mydia/indexers/adapter/registry.ex`. Provides a tiny
//! `Arc<dyn IndexerAdapter>` indirection so callers can register
//! adapters at boot and look them up by ID at search time.

use std::sync::Arc;

use dashmap::DashMap;

use crate::adapter::{AdapterConfig, AdapterKind, IndexerAdapter};

/// Adapter registry. Cheap to clone (one `Arc` per clone).
#[derive(Clone, Default)]
pub struct IndexerRegistry {
    adapters: Arc<DashMap<AdapterKind, Arc<dyn IndexerAdapter>>>,
    configs: Arc<DashMap<String, AdapterConfig>>,
}

impl IndexerRegistry {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Register an adapter for an [`AdapterKind`]. Subsequent calls
    /// replace the previous registration.
    pub fn register(&self, kind: AdapterKind, adapter: Arc<dyn IndexerAdapter>) {
        self.adapters.insert(kind, adapter);
    }

    /// Look up the adapter for an [`AdapterKind`].
    #[must_use]
    pub fn adapter(&self, kind: AdapterKind) -> Option<Arc<dyn IndexerAdapter>> {
        self.adapters.get(&kind).map(|entry| entry.value().clone())
    }

    /// Store a per-instance configuration, keyed by `config.id`.
    pub fn store_config(&self, config: AdapterConfig) {
        self.configs.insert(config.id.clone(), config);
    }

    /// Look up an instance configuration by stable ID.
    #[must_use]
    pub fn config(&self, id: &str) -> Option<AdapterConfig> {
        self.configs.get(id).map(|entry| entry.value().clone())
    }

    /// Snapshot every registered configuration.
    #[must_use]
    pub fn list_configs(&self) -> Vec<AdapterConfig> {
        self.configs
            .iter()
            .map(|entry| entry.value().clone())
            .collect()
    }

    /// Drop a registered configuration. The adapter table is untouched.
    pub fn remove_config(&self, id: &str) {
        self.configs.remove(id);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::adapter::{Capabilities, ConnectionInfo, IndexerAdapter, SearchOpts};
    use crate::error::IndexerError;
    use crate::search_result::SearchResult;
    use async_trait::async_trait;

    struct DummyAdapter;

    #[async_trait]
    impl IndexerAdapter for DummyAdapter {
        async fn test_connection(
            &self,
            _config: &AdapterConfig,
        ) -> Result<ConnectionInfo, IndexerError> {
            Ok(ConnectionInfo {
                name: Some("dummy".into()),
                version: None,
                details: serde_json::Value::Null,
            })
        }
        async fn search(
            &self,
            _config: &AdapterConfig,
            _query: &str,
            _opts: &SearchOpts,
        ) -> Result<Vec<SearchResult>, IndexerError> {
            Ok(Vec::new())
        }
        async fn capabilities(
            &self,
            _config: &AdapterConfig,
        ) -> Result<Capabilities, IndexerError> {
            Ok(Capabilities::default())
        }
    }

    #[test]
    fn register_and_lookup_adapter() {
        let r = IndexerRegistry::new();
        r.register(AdapterKind::Cardigann, Arc::new(DummyAdapter));
        assert!(r.adapter(AdapterKind::Cardigann).is_some());
        assert!(r.adapter(AdapterKind::Prowlarr).is_none());
    }

    #[test]
    fn config_store_round_trips() {
        let r = IndexerRegistry::new();
        let cfg = AdapterConfig {
            r#type: AdapterKind::Cardigann,
            name: "Test".into(),
            base_url: "https://example.org".into(),
            api_key: None,
            options: serde_json::Value::Null,
            id: "x".into(),
            rate_limit: Some(60),
        };
        r.store_config(cfg);
        assert!(r.config("x").is_some());
        assert_eq!(r.list_configs().len(), 1);
        r.remove_config("x");
        assert!(r.config("x").is_none());
    }
}
