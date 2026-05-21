//! Client registry. Tokio/dashmap replacement for the per-client
//! lookup logic in `lib/mydia/downloads/client/registry.ex`.
//!
//! Phoenix's registry is little more than a lookup table from
//! `client_type` atom to module — the work it does happens at the
//! call site. The Rust port flattens that into one
//! `DashMap<&'static str, Arc<dyn DownloadClient>>` indexed by adapter
//! name. U17 populates the registry once at boot from the default set
//! and refreshes if the admin `LiveView` adds a new adapter type.

use std::sync::Arc;

use dashmap::DashMap;

use crate::adapter::{DownloadClient, Protocol};

/// Adapter-name-keyed lookup table. Cheap to clone (one `Arc` per
/// clone); shared between the U17 worker and U33 admin endpoints.
#[derive(Clone, Default)]
pub struct ClientRegistry {
    entries: Arc<DashMap<&'static str, Arc<dyn DownloadClient>>>,
}

impl ClientRegistry {
    /// Empty registry. Populated by [`Self::register`].
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Build the production-default registry containing every adapter
    /// this crate ships. U17 calls this once at boot.
    #[must_use]
    pub fn with_defaults() -> Self {
        let registry = Self::new();
        registry.register(Arc::new(crate::clients::qbittorrent::QBittorrentClient));
        registry.register(Arc::new(crate::clients::transmission::TransmissionClient));
        registry.register(Arc::new(crate::clients::rtorrent::RtorrentClient));
        registry.register(Arc::new(crate::clients::sabnzbd::SabnzbdClient));
        registry.register(Arc::new(crate::clients::nzbget::NzbgetClient));
        registry.register(Arc::new(crate::clients::blackhole::BlackholeClient));
        registry.register(Arc::new(crate::clients::debrid::DebridClient::new()));
        registry
    }

    /// Insert (or replace) an adapter keyed by its `name()`.
    pub fn register(&self, client: Arc<dyn DownloadClient>) {
        self.entries.insert(client.name(), client);
    }

    /// Look up an adapter by name. Returns `None` if no adapter has
    /// been registered under that name.
    pub fn get(&self, name: &str) -> Option<Arc<dyn DownloadClient>> {
        self.entries.get(name).map(|entry| entry.value().clone())
    }

    /// All adapters that declare support for `protocol`. Used by the
    /// U17 release orchestrator when picking which client to hand a
    /// torrent / NZB to.
    pub fn for_protocol(&self, protocol: Protocol) -> Vec<Arc<dyn DownloadClient>> {
        self.entries
            .iter()
            .filter(|entry| entry.value().supported_protocols().contains(&protocol))
            .map(|entry| entry.value().clone())
            .collect()
    }

    /// Snapshot of every registered adapter name. Diagnostic only.
    pub fn names(&self) -> Vec<&'static str> {
        self.entries.iter().map(|entry| *entry.key()).collect()
    }

    /// Number of registered adapters.
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    /// True when no adapters are registered.
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_register_all_seven_adapters() {
        let registry = ClientRegistry::with_defaults();
        assert_eq!(registry.len(), 7);
        for name in [
            "qbittorrent",
            "transmission",
            "rtorrent",
            "sabnzbd",
            "nzbget",
            "blackhole",
            "debrid",
        ] {
            assert!(registry.get(name).is_some(), "missing adapter {name}");
        }
    }

    #[test]
    fn torrent_protocol_picks_torrent_adapters() {
        let registry = ClientRegistry::with_defaults();
        let torrent_adapters = registry.for_protocol(Protocol::Torrent);
        let torrent_names: Vec<_> = torrent_adapters.iter().map(|a| a.name()).collect();
        assert!(torrent_names.contains(&"qbittorrent"));
        assert!(torrent_names.contains(&"transmission"));
        assert!(torrent_names.contains(&"rtorrent"));
        assert!(torrent_names.contains(&"blackhole"));
        assert!(torrent_names.contains(&"debrid"));
        // SABnzbd / NZBGet are nzb-only.
        assert!(!torrent_names.contains(&"sabnzbd"));
        assert!(!torrent_names.contains(&"nzbget"));
    }

    #[test]
    fn nzb_protocol_picks_nzb_adapters() {
        let registry = ClientRegistry::with_defaults();
        let nzb_adapters = registry.for_protocol(Protocol::Nzb);
        let nzb_names: Vec<_> = nzb_adapters.iter().map(|a| a.name()).collect();
        assert!(nzb_names.contains(&"sabnzbd"));
        assert!(nzb_names.contains(&"nzbget"));
        // The torrent-only adapters don't accept NZBs.
        assert!(!nzb_names.contains(&"qbittorrent"));
    }
}
