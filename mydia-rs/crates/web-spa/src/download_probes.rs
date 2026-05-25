//! In-process probe cache for download-client connectivity tests.
//!
//! Phoenix counterpart: `Mydia.Downloads.ClientHealth`, a `GenServer`
//! that runs periodic `test_connection` probes against every
//! configured download client and caches the result keyed by id. The
//! admin UI reads the cache rather than firing a fresh probe per
//! page render.
//!
//! The Rust port keeps the same shape: a small `DashMap<id, (Instant,
//! ConnectionTest)>` shared via `WebState`. Probes are issued on
//! demand (admin clicks "Test connection" in the page); the cache
//! returns the prior result if it's younger than the TTL, otherwise
//! it kicks off a fresh probe and updates the entry. The 60-second
//! default TTL matches the Phoenix `GenServer`'s `@cache_ttl_ms` and
//! is configurable so tests can pin it.
//!
//! Dispatch goes through the [`ClientRegistry`] from
//! `crates/downloads/`: each adapter implements `test_connection`
//! against its own protocol (qBittorrent API auth, Transmission RPC
//! ping, `SABnzbd` API key check, etc.). Per-adapter wirings live in
//! the downloads crate — they're already shipped; this cache layer
//! is the dispatch surface the admin page consumes.
//!
//! Cache invalidation: clearing the entire cache on
//! [`ProbeCache::invalidate_all`] forces every subsequent probe to
//! hit the network, which the admin "Refresh" action calls into
//! during the next U28 follow-up sweep. Per-id invalidation is also
//! available for the create/delete flow.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, Instant};

use dashmap::DashMap;
use mydia_rs_downloads::adapter::{ClientConfig, DownloadClient};
use mydia_rs_downloads::registry::ClientRegistry;

/// Default TTL for cached probe results. Matches the Phoenix
/// `Mydia.Downloads.ClientHealth.@cache_ttl_ms` constant. Configurable
/// via [`ProbeCache::with_ttl`] for tests that want to exercise the
/// expiry path deterministically.
pub const DEFAULT_TTL: Duration = Duration::from_secs(60);

/// Cached probe outcome. Carries the same shape the admin page renders
/// today — a boolean plus a one-line message. The `ts` field records
/// when the entry was populated so [`ProbeCache::probe`] knows when to
/// refresh.
#[derive(Debug, Clone)]
pub struct ProbeEntry {
    pub ok: bool,
    pub message: String,
    pub ts: Instant,
}

/// Probe cache. Cheap to clone (one `Arc` per clone); the inner
/// `DashMap` provides interior mutability so the cache lives behind a
/// shared `Arc` without `RwLock` ceremony.
#[derive(Clone)]
pub struct ProbeCache {
    entries: Arc<DashMap<String, ProbeEntry>>,
    registry: ClientRegistry,
    ttl: Duration,
}

impl Default for ProbeCache {
    fn default() -> Self {
        Self::new()
    }
}

impl ProbeCache {
    /// Build a fresh cache backed by the production-default
    /// [`ClientRegistry`]. Boot path calls this once and shares the
    /// resulting handle through `WebState`.
    #[must_use]
    pub fn new() -> Self {
        Self {
            entries: Arc::new(DashMap::new()),
            registry: ClientRegistry::with_defaults(),
            ttl: DEFAULT_TTL,
        }
    }

    /// Override the cache TTL. Used by tests; the production path
    /// keeps the default 60s.
    #[must_use]
    pub fn with_ttl(mut self, ttl: Duration) -> Self {
        self.ttl = ttl;
        self
    }

    /// Override the underlying client registry. Used by tests that
    /// register stub adapters for deterministic probe outcomes.
    #[must_use]
    pub fn with_registry(mut self, registry: ClientRegistry) -> Self {
        self.registry = registry;
        self
    }

    /// Look up the cached probe entry for a client id, returning
    /// `None` when no entry exists or the entry has expired past the
    /// configured TTL. Pure read; never issues a network call.
    pub fn cached(&self, id: &str) -> Option<ProbeEntry> {
        let entry = self.entries.get(id)?.clone();
        if entry.ts.elapsed() >= self.ttl {
            return None;
        }
        Some(entry)
    }

    /// Invalidate the entry for one client id. Called by the admin
    /// create / update / delete flows so the next `test_connection` call
    /// re-probes against the new config.
    pub fn invalidate(&self, id: &str) {
        self.entries.remove(id);
    }

    /// Drop every cached entry. The admin "Refresh" action calls this
    /// to force a fresh sweep across every configured client.
    pub fn invalidate_all(&self) {
        self.entries.clear();
    }

    /// Probe a client and return the result, populating the cache on
    /// the way. If a cached entry is still fresh, returns it without
    /// issuing a network call.
    ///
    /// The `kind` argument selects an adapter from the registry. If
    /// the adapter is unknown, the probe short-circuits with a
    /// canonical error message; the cache still records the failure
    /// so the page doesn't spin retrying the same unknown kind.
    pub async fn probe(&self, id: &str, kind: &str, config: ClientConfig) -> ProbeEntry {
        if let Some(cached) = self.cached(id) {
            return cached;
        }
        let entry = self.run_probe(kind, config).await;
        self.entries.insert(id.to_owned(), entry.clone());
        entry
    }

    async fn run_probe(&self, kind: &str, config: ClientConfig) -> ProbeEntry {
        let Some(adapter) = self.registry.get(kind) else {
            return ProbeEntry {
                ok: false,
                message: format!("no adapter registered for kind {kind:?}"),
                ts: Instant::now(),
            };
        };
        match adapter.test_connection(&config).await {
            Ok(info) => ProbeEntry {
                ok: true,
                message: probe_success_message(adapter.as_ref(), &info.version),
                ts: Instant::now(),
            },
            Err(err) => ProbeEntry {
                ok: false,
                message: format!("{kind}: {err}"),
                ts: Instant::now(),
            },
        }
    }

    /// Number of currently-cached entries. Diagnostic / test only.
    #[must_use]
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    /// True when the cache holds zero entries.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }
}

/// Compose the success message rendered by the admin page. Keeps the
/// format consistent with the previous shape-check probe so the UI
/// renders the same line for both code paths.
fn probe_success_message(adapter: &dyn DownloadClient, version: &str) -> String {
    let name = adapter.name();
    if version.trim().is_empty() {
        format!("{name} reachable")
    } else {
        format!("{name} reachable (version {version})")
    }
}

/// Parse a URL string into the `host`/`port`/`use_ssl` triple the
/// adapter trait expects. Returns `Err` with a human-readable message
/// when the URL doesn't parse. Path components fold into `url_base` so
/// rTorrent's `/RPC2` and `SABnzbd`'s `/sabnzbd` work end-to-end.
pub fn config_from_url(
    url: &str,
    username: Option<&str>,
    password: Option<&str>,
) -> Result<ClientConfig, String> {
    let parsed = url::Url::parse(url).map_err(|err| format!("parse url {url:?}: {err}"))?;
    let scheme = parsed.scheme();
    let use_ssl = matches!(scheme, "https");
    if !matches!(scheme, "http" | "https") {
        return Err(format!("unsupported scheme {scheme:?}"));
    }
    let host = parsed
        .host_str()
        .ok_or_else(|| format!("url {url:?} has no host"))?
        .to_owned();
    let port = parsed.port().unwrap_or(if use_ssl { 443 } else { 80 });
    let path = parsed.path();
    let url_base = if path.is_empty() || path == "/" {
        None
    } else {
        Some(path.to_owned())
    };
    Ok(ClientConfig {
        host,
        port,
        use_ssl,
        username: username.map(str::to_owned),
        password: password.map(str::to_owned),
        api_key: None,
        url_base,
        options: HashMap::new(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use async_trait::async_trait;
    use mydia_rs_downloads::adapter::{
        AddOpts, ClientInfo, DownloadStatus, ListOpts, Protocol, TorrentInput,
    };
    use mydia_rs_downloads::error::DownloadError;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;

    /// Stub adapter that counts how many times `test_connection` is
    /// called. Lets the cache tests pin TTL behaviour without doing
    /// any real network IO.
    struct CountingAdapter {
        name: &'static str,
        calls: Arc<AtomicUsize>,
        result: Result<ClientInfo, &'static str>,
    }

    #[async_trait]
    impl DownloadClient for CountingAdapter {
        fn name(&self) -> &'static str {
            self.name
        }
        fn supported_protocols(&self) -> &'static [Protocol] {
            &[Protocol::Torrent]
        }
        async fn test_connection(
            &self,
            _config: &ClientConfig,
        ) -> Result<ClientInfo, DownloadError> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            self.result
                .clone()
                .map_err(|msg| DownloadError::Network(msg.to_owned()))
        }
        async fn add(
            &self,
            _: &ClientConfig,
            _: TorrentInput,
            _: AddOpts,
        ) -> Result<String, DownloadError> {
            unimplemented!()
        }
        async fn list_active(
            &self,
            _: &ClientConfig,
            _: ListOpts,
        ) -> Result<Vec<DownloadStatus>, DownloadError> {
            unimplemented!()
        }
        async fn cancel(&self, _: &ClientConfig, _: &str, _: bool) -> Result<(), DownloadError> {
            unimplemented!()
        }
        async fn get_files(&self, _: &ClientConfig, _: &str) -> Result<Vec<String>, DownloadError> {
            unimplemented!()
        }
        async fn get_save_path(&self, _: &ClientConfig, _: &str) -> Result<String, DownloadError> {
            unimplemented!()
        }
    }

    fn fixture(result: Result<ClientInfo, &'static str>) -> (ProbeCache, Arc<AtomicUsize>) {
        let calls = Arc::new(AtomicUsize::new(0));
        let registry = ClientRegistry::new();
        let adapter = Arc::new(CountingAdapter {
            name: "qbittorrent",
            calls: calls.clone(),
            result,
        });
        registry.register(adapter);
        let cache = ProbeCache::new()
            .with_registry(registry)
            .with_ttl(Duration::from_millis(50));
        (cache, calls)
    }

    fn cfg() -> ClientConfig {
        ClientConfig {
            host: "localhost".into(),
            port: 8080,
            ..Default::default()
        }
    }

    #[tokio::test]
    async fn probe_runs_once_then_returns_cached_entry() {
        let (cache, calls) = fixture(Ok(ClientInfo {
            version: "5.0.0".into(),
            ..Default::default()
        }));

        let first = cache.probe("id-1", "qbittorrent", cfg()).await;
        assert!(first.ok);
        assert!(first.message.contains("5.0.0"));

        let second = cache.probe("id-1", "qbittorrent", cfg()).await;
        assert!(second.ok);
        assert_eq!(
            calls.load(Ordering::SeqCst),
            1,
            "cached entry skips the network call"
        );
    }

    #[tokio::test]
    async fn probe_refreshes_after_ttl_expires() {
        let (cache, calls) = fixture(Ok(ClientInfo {
            version: "5.0.0".into(),
            ..Default::default()
        }));

        cache.probe("id-1", "qbittorrent", cfg()).await;
        tokio::time::sleep(Duration::from_millis(80)).await;
        cache.probe("id-1", "qbittorrent", cfg()).await;
        assert_eq!(calls.load(Ordering::SeqCst), 2, "TTL expiry forces refresh");
    }

    #[tokio::test]
    async fn probe_records_unreachable_failure() {
        let (cache, calls) = fixture(Err("connection refused"));
        let entry = cache.probe("id-1", "qbittorrent", cfg()).await;
        assert!(!entry.ok, "failure surfaces ok=false");
        assert!(
            entry.message.contains("connection refused"),
            "error message threaded through"
        );
        assert_eq!(calls.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn probe_unknown_kind_short_circuits() {
        let (cache, calls) = fixture(Ok(ClientInfo::default()));
        let entry = cache.probe("id-1", "mystery", cfg()).await;
        assert!(!entry.ok);
        assert!(entry.message.contains("no adapter registered"));
        assert_eq!(
            calls.load(Ordering::SeqCst),
            0,
            "unknown kind never dispatched"
        );
    }

    #[tokio::test]
    async fn invalidate_drops_cached_entry() {
        let (cache, calls) = fixture(Ok(ClientInfo::default()));
        cache.probe("id-1", "qbittorrent", cfg()).await;
        cache.invalidate("id-1");
        cache.probe("id-1", "qbittorrent", cfg()).await;
        assert_eq!(calls.load(Ordering::SeqCst), 2, "invalidate forces refresh");
    }

    #[test]
    fn config_from_url_parses_http() {
        let cfg = config_from_url("http://localhost:8080", None, None).expect("parse");
        assert_eq!(cfg.host, "localhost");
        assert_eq!(cfg.port, 8080);
        assert!(!cfg.use_ssl);
        assert!(cfg.url_base.is_none());
    }

    #[test]
    fn config_from_url_parses_https_with_path() {
        let cfg = config_from_url(
            "https://example.com:9091/transmission/rpc",
            Some("u"),
            Some("p"),
        )
        .expect("parse");
        assert_eq!(cfg.host, "example.com");
        assert_eq!(cfg.port, 9091);
        assert!(cfg.use_ssl);
        assert_eq!(cfg.url_base.as_deref(), Some("/transmission/rpc"));
        assert_eq!(cfg.username.as_deref(), Some("u"));
        assert_eq!(cfg.password.as_deref(), Some("p"));
    }

    #[test]
    fn config_from_url_rejects_unparseable() {
        assert!(config_from_url("not a url", None, None).is_err());
    }

    #[test]
    fn config_from_url_rejects_unsupported_scheme() {
        assert!(config_from_url("ftp://example.com", None, None).is_err());
    }
}
