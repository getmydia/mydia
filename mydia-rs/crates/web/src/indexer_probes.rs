//! In-process probe cache for indexer connectivity tests.
//!
//! Phoenix counterpart: `Mydia.Indexers.Health`, a `GenServer` that
//! runs periodic `test_connection` probes against every configured
//! indexer and caches the result keyed by id, plus an ETS-backed
//! consecutive-failure counter. The admin UI and operator REST surface
//! read the cache rather than firing a fresh probe per page render.
//!
//! The Rust port mirrors the download-client side
//! ([`crate::download_probes::ProbeCache`]): a small
//! `DashMap<id, IndexerProbeEntry>` shared via `WebState`. Probes are
//! issued on demand (admin clicks "Test" in the page, or operator
//! POSTs to `/api/v1/indexers/:id/test`); the cache returns the prior
//! result if it's younger than the TTL, otherwise it kicks off a
//! fresh probe and updates the entry. The default 60-second TTL
//! matches the [`crate::download_probes::DEFAULT_TTL`] used for the
//! sibling surface so the operator UI's "Test"-then-refresh latency
//! is consistent across both. Tests can override the TTL via
//! [`IndexerProbeCache::with_ttl`].
//!
//! Dispatch goes through the [`IndexerRegistry`] from
//! `crates/indexers/`: each adapter implements `test_connection`
//! against its own protocol. Unknown kinds short-circuit with a
//! canonical error message so the cache doesn't spin retrying a kind
//! the operator typoed. The Cardigann engine port is the dominant
//! adapter; per-engine wirings stay in the indexers crate.
//!
//! Cache invalidation: clearing the entire cache on
//! [`IndexerProbeCache::invalidate_all`] forces every subsequent
//! probe to hit the network, which the operator "Refresh" action
//! calls into. Per-id invalidation is also available for the
//! create / update / delete flow.
//!
//! Consecutive-failure tracking: the Phoenix `Indexers.Health` module
//! also tracks a per-id consecutive-failure counter that survives
//! cache eviction (stored in a separate `:indexer_failures` ETS
//! table). We mirror that here with a sibling `DashMap` so
//! [`IndexerProbeCache::invalidate`] can drop the cached verdict
//! without resetting the alert trail. The dedicated
//! [`IndexerProbeCache::reset_failures`] entry point is the only path
//! that zeroes the counter — matches Phoenix's
//! `Health.reset_failures/1` call shape.

use std::sync::Arc;
use std::time::{Duration, Instant};

use dashmap::DashMap;
use mydia_rs_indexers::adapter::{AdapterConfig, AdapterKind, IndexerAdapter};
use mydia_rs_indexers::registry::IndexerRegistry;

/// Default TTL for cached probe results. Mirrors
/// [`crate::download_probes::DEFAULT_TTL`] for consistency across the
/// two operator probe surfaces. Configurable via
/// [`IndexerProbeCache::with_ttl`] for tests that exercise the expiry
/// path deterministically.
pub const DEFAULT_TTL: Duration = Duration::from_secs(60);

/// Cached probe outcome. Carries the same shape the admin page and
/// REST endpoint render: a boolean verdict plus a one-line message,
/// the wall-clock time of the probe, and the running
/// consecutive-failure count for the indexer.
#[derive(Debug, Clone)]
pub struct IndexerProbeEntry {
    pub ok: bool,
    pub message: String,
    pub ts: Instant,
    pub consecutive_failures: u32,
}

/// Probe cache. Cheap to clone (one `Arc` per clone); the inner
/// `DashMap` provides interior mutability so the cache lives behind a
/// shared `Arc` without `RwLock` ceremony.
///
/// `entries` holds the per-id probe results with TTL freshness;
/// `failures` holds the per-id consecutive-failure counter that
/// survives entry eviction. Splitting them mirrors Phoenix's
/// `(:indexer_health, :indexer_failures)` ETS table pair so the
/// invalidate / reset semantics line up.
#[derive(Clone)]
pub struct IndexerProbeCache {
    entries: Arc<DashMap<String, IndexerProbeEntry>>,
    failures: Arc<DashMap<String, u32>>,
    registry: IndexerRegistry,
    ttl: Duration,
}

impl Default for IndexerProbeCache {
    fn default() -> Self {
        Self::new()
    }
}

impl IndexerProbeCache {
    /// Build a fresh cache backed by an empty
    /// [`IndexerRegistry`]. Boot path calls this once and shares the
    /// resulting handle through `WebState`. The boot path is
    /// responsible for registering each adapter implementation against
    /// the registry before the first probe.
    #[must_use]
    pub fn new() -> Self {
        Self {
            entries: Arc::new(DashMap::new()),
            failures: Arc::new(DashMap::new()),
            registry: IndexerRegistry::new(),
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

    /// Override the underlying indexer registry. Used by tests that
    /// register stub adapters for deterministic probe outcomes and by
    /// the boot path to wire the real Cardigann adapter implementation.
    #[must_use]
    pub fn with_registry(mut self, registry: IndexerRegistry) -> Self {
        self.registry = registry;
        self
    }

    /// Look up the cached probe entry for an indexer id, returning
    /// `None` when no entry exists or the entry has expired past the
    /// configured TTL. Pure read; never issues a network call.
    pub fn cached(&self, id: &str) -> Option<IndexerProbeEntry> {
        let entry = self.entries.get(id)?.clone();
        if entry.ts.elapsed() >= self.ttl {
            return None;
        }
        Some(entry)
    }

    /// Look up the consecutive-failure count for an indexer id,
    /// independent of the probe entry's TTL. Mirrors Phoenix's
    /// `Health.get_failure_count/1` which reads from the
    /// `:indexer_failures` ETS table.
    ///
    /// The counter persists across [`Self::invalidate`] so a config
    /// write doesn't reset the operator's alert trail; only
    /// [`Self::reset_failures`] (or a successful probe) zeroes it.
    #[must_use]
    pub fn failure_count(&self, id: &str) -> u32 {
        self.failures.get(id).map_or(0, |entry| *entry.value())
    }

    /// Invalidate the entry for one indexer id. Called by the admin
    /// create / update / delete flows so the next `test_connection`
    /// call re-probes against the new config.
    ///
    /// The consecutive-failure counter is preserved across
    /// invalidations because operator config changes shouldn't reset
    /// the alert trail; use [`IndexerProbeCache::reset_failures`] for
    /// the explicit reset path the operator triggers via the REST
    /// `:id/reset-failures` endpoint.
    pub fn invalidate(&self, id: &str) {
        self.entries.remove(id);
    }

    /// Drop every cached entry. The operator "Refresh" REST action
    /// calls this to force a fresh sweep across every configured
    /// indexer. Consecutive-failure counters are dropped here too —
    /// the operator's intent is "reset everything for a fresh look".
    pub fn invalidate_all(&self) {
        self.entries.clear();
        self.failures.clear();
    }

    /// Reset the consecutive-failure counter for one indexer id.
    /// Mirrors Phoenix's `Health.reset_failures/1` `GenServer` call.
    /// The cached entry's freshness is left alone so the operator
    /// still sees the most recent verdict; only the failure trail is
    /// cleared.
    pub fn reset_failures(&self, id: &str) {
        self.failures.remove(id);
    }

    /// Probe an indexer and return the result, populating the cache
    /// on the way. If a cached entry is still fresh, returns it
    /// without issuing a network call.
    ///
    /// The `kind` argument selects an adapter from the registry. If
    /// the adapter is unknown, the probe short-circuits with a
    /// canonical error message; the cache still records the failure
    /// so the page doesn't spin retrying the same unknown kind.
    pub async fn probe(
        &self,
        id: &str,
        kind: AdapterKind,
        config: AdapterConfig,
    ) -> IndexerProbeEntry {
        if let Some(cached) = self.cached(id) {
            return cached;
        }
        let entry = self.run_probe(id, kind, config).await;
        self.entries.insert(id.to_owned(), entry.clone());
        entry
    }

    async fn run_probe(
        &self,
        id: &str,
        kind: AdapterKind,
        config: AdapterConfig,
    ) -> IndexerProbeEntry {
        let Some(adapter) = self.registry.adapter(kind) else {
            let count = self.bump_failure(id);
            return IndexerProbeEntry {
                ok: false,
                message: format!("no adapter registered for kind {kind:?}"),
                ts: Instant::now(),
                consecutive_failures: count,
            };
        };
        match adapter.test_connection(&config).await {
            Ok(info) => {
                // A successful probe resets the failure trail in the
                // same way Phoenix's `do_health_check` deletes the
                // `:indexer_failures` row on `:healthy`.
                self.failures.remove(id);
                IndexerProbeEntry {
                    ok: true,
                    message: probe_success_message(
                        adapter.as_ref(),
                        info.name.as_deref(),
                        info.version.as_deref(),
                    ),
                    ts: Instant::now(),
                    consecutive_failures: 0,
                }
            }
            Err(err) => {
                let count = self.bump_failure(id);
                IndexerProbeEntry {
                    ok: false,
                    message: format!("{}: {}", config.name, err),
                    ts: Instant::now(),
                    consecutive_failures: count,
                }
            }
        }
    }

    /// Increment the failure counter for one indexer id and return
    /// the new count. Splitting this out keeps the probe path tidy
    /// and avoids touching the `entries` map on the failure branch.
    fn bump_failure(&self, id: &str) -> u32 {
        let mut entry = self.failures.entry(id.to_owned()).or_insert(0);
        *entry = entry.saturating_add(1);
        *entry
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

/// Compose the success message rendered by the operator UI / REST
/// payload. Falls back to the adapter type label when the indexer
/// returned no name; includes the version when present so operators
/// can spot version drift across instances.
fn probe_success_message(
    _adapter: &dyn IndexerAdapter,
    name: Option<&str>,
    version: Option<&str>,
) -> String {
    let name = name.unwrap_or("indexer");
    match version {
        Some(v) if !v.trim().is_empty() => format!("{name} reachable (version {v})"),
        _ => format!("{name} reachable"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use async_trait::async_trait;
    use mydia_rs_indexers::adapter::{
        AdapterConfig, AdapterKind, Capabilities, ConnectionInfo, IndexerAdapter, SearchOpts,
    };
    use mydia_rs_indexers::error::IndexerError;
    use mydia_rs_indexers::search_result::SearchResult;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;

    /// Stub adapter that counts how many times `test_connection` is
    /// called. Lets the cache tests pin TTL behaviour without doing
    /// any real network IO.
    struct CountingAdapter {
        calls: Arc<AtomicUsize>,
        result: Result<ConnectionInfo, &'static str>,
    }

    #[async_trait]
    impl IndexerAdapter for CountingAdapter {
        async fn test_connection(
            &self,
            _config: &AdapterConfig,
        ) -> Result<ConnectionInfo, IndexerError> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            self.result.clone().map_err(IndexerError::connection_failed)
        }
        async fn search(
            &self,
            _: &AdapterConfig,
            _: &str,
            _: &SearchOpts,
        ) -> Result<Vec<SearchResult>, IndexerError> {
            unimplemented!()
        }
        async fn capabilities(&self, _: &AdapterConfig) -> Result<Capabilities, IndexerError> {
            unimplemented!()
        }
    }

    fn fixture(
        result: Result<ConnectionInfo, &'static str>,
    ) -> (IndexerProbeCache, Arc<AtomicUsize>) {
        let calls = Arc::new(AtomicUsize::new(0));
        let registry = IndexerRegistry::new();
        let adapter = Arc::new(CountingAdapter {
            calls: calls.clone(),
            result,
        });
        registry.register(AdapterKind::Cardigann, adapter);
        let cache = IndexerProbeCache::new()
            .with_registry(registry)
            .with_ttl(Duration::from_millis(50));
        (cache, calls)
    }

    fn cfg(id: &str) -> AdapterConfig {
        AdapterConfig {
            r#type: AdapterKind::Cardigann,
            name: "test-indexer".into(),
            base_url: "https://example.org".into(),
            api_key: None,
            options: serde_json::Value::Null,
            id: id.to_owned(),
            rate_limit: Some(60),
        }
    }

    fn ok_info() -> ConnectionInfo {
        ConnectionInfo {
            name: Some("example".into()),
            version: Some("1.0".into()),
            details: serde_json::Value::Null,
        }
    }

    #[tokio::test]
    async fn probe_runs_once_then_returns_cached_entry() {
        let (cache, calls) = fixture(Ok(ok_info()));

        let first = cache
            .probe("id-1", AdapterKind::Cardigann, cfg("id-1"))
            .await;
        assert!(first.ok);
        assert!(first.message.contains("1.0"));

        let second = cache
            .probe("id-1", AdapterKind::Cardigann, cfg("id-1"))
            .await;
        assert!(second.ok);
        assert_eq!(
            calls.load(Ordering::SeqCst),
            1,
            "cached entry skips the network call"
        );
    }

    #[tokio::test]
    async fn probe_refreshes_after_ttl_expires() {
        let (cache, calls) = fixture(Ok(ok_info()));

        cache
            .probe("id-1", AdapterKind::Cardigann, cfg("id-1"))
            .await;
        tokio::time::sleep(Duration::from_millis(80)).await;
        cache
            .probe("id-1", AdapterKind::Cardigann, cfg("id-1"))
            .await;
        assert_eq!(calls.load(Ordering::SeqCst), 2, "TTL expiry forces refresh");
    }

    #[tokio::test]
    async fn probe_records_unreachable_failure_and_bumps_failure_count() {
        let (cache, calls) = fixture(Err("connection refused"));
        let entry = cache
            .probe("id-1", AdapterKind::Cardigann, cfg("id-1"))
            .await;
        assert!(!entry.ok, "failure surfaces ok=false");
        assert!(
            entry.message.contains("connection refused"),
            "error message threaded through"
        );
        assert_eq!(entry.consecutive_failures, 1);
        assert_eq!(calls.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn invalidate_drops_cached_entry_but_keeps_failure_count() {
        let (cache, calls) = fixture(Err("connection refused"));
        cache
            .probe("id-1", AdapterKind::Cardigann, cfg("id-1"))
            .await;
        assert_eq!(cache.failure_count("id-1"), 1);

        cache.invalidate("id-1");
        // Failure count is preserved across config-write invalidations
        // so the operator alert trail survives cache churn.
        assert_eq!(cache.failure_count("id-1"), 1);
        assert!(cache.cached("id-1").is_none(), "entry evicted");

        let entry = cache
            .probe("id-1", AdapterKind::Cardigann, cfg("id-1"))
            .await;
        assert!(!entry.ok);
        assert_eq!(
            entry.consecutive_failures, 2,
            "failure count keeps climbing"
        );
        assert_eq!(calls.load(Ordering::SeqCst), 2);
    }

    #[tokio::test]
    async fn invalidate_all_drops_every_entry_and_resets_failure_counters() {
        let (cache, _calls) = fixture(Ok(ok_info()));
        cache
            .probe("id-1", AdapterKind::Cardigann, cfg("id-1"))
            .await;
        cache
            .probe("id-2", AdapterKind::Cardigann, cfg("id-2"))
            .await;
        assert_eq!(cache.len(), 2);
        cache.invalidate_all();
        assert!(cache.is_empty());
        assert_eq!(cache.failure_count("id-1"), 0);
    }

    #[tokio::test]
    async fn reset_failures_zeroes_counter_without_dropping_entry() {
        let (cache, _calls) = fixture(Err("nope"));
        cache
            .probe("id-1", AdapterKind::Cardigann, cfg("id-1"))
            .await;
        let count = cache.failure_count("id-1");
        assert!(count >= 1, "expected at least one failure, got {count}");
        cache.reset_failures("id-1");
        assert_eq!(cache.failure_count("id-1"), 0);
        // The cached entry is still there — read-only callers see the
        // unhealthy verdict until the next forced probe.
        assert!(cache.cached("id-1").is_some());
    }

    #[tokio::test]
    async fn successful_probe_resets_failure_counter() {
        // First fixture is configured to fail; mid-test we swap the
        // result on the shared adapter so the next probe succeeds.
        let calls = Arc::new(AtomicUsize::new(0));
        let registry = IndexerRegistry::new();
        let adapter = Arc::new(SwitchingAdapter {
            calls: calls.clone(),
            result: std::sync::Mutex::new(Err("connection refused")),
        });
        registry.register(AdapterKind::Cardigann, adapter.clone());
        let cache = IndexerProbeCache::new()
            .with_registry(registry)
            .with_ttl(Duration::from_millis(50));

        cache
            .probe("id-1", AdapterKind::Cardigann, cfg("id-1"))
            .await;
        assert_eq!(cache.failure_count("id-1"), 1);

        // Flip the adapter to ok, expire the cache, re-probe.
        *adapter.result.lock().unwrap() = Ok(ok_info());
        tokio::time::sleep(Duration::from_millis(80)).await;
        let entry = cache
            .probe("id-1", AdapterKind::Cardigann, cfg("id-1"))
            .await;
        assert!(entry.ok);
        assert_eq!(cache.failure_count("id-1"), 0);
    }

    /// Adapter whose `test_connection` result can be swapped at
    /// runtime. Lets the "successful probe resets counter" test
    /// alternate failure / success without re-building the cache.
    struct SwitchingAdapter {
        calls: Arc<AtomicUsize>,
        result: std::sync::Mutex<Result<ConnectionInfo, &'static str>>,
    }

    #[async_trait]
    impl IndexerAdapter for SwitchingAdapter {
        async fn test_connection(
            &self,
            _config: &AdapterConfig,
        ) -> Result<ConnectionInfo, IndexerError> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            self.result
                .lock()
                .unwrap()
                .clone()
                .map_err(IndexerError::connection_failed)
        }
        async fn search(
            &self,
            _: &AdapterConfig,
            _: &str,
            _: &SearchOpts,
        ) -> Result<Vec<SearchResult>, IndexerError> {
            unimplemented!()
        }
        async fn capabilities(&self, _: &AdapterConfig) -> Result<Capabilities, IndexerError> {
            unimplemented!()
        }
    }

    #[tokio::test]
    async fn probe_unknown_kind_short_circuits() {
        let calls = Arc::new(AtomicUsize::new(0));
        let registry = IndexerRegistry::new();
        let adapter = Arc::new(CountingAdapter {
            calls: calls.clone(),
            result: Ok(ok_info()),
        });
        // Register an adapter but for a different kind so the probe
        // for `Prowlarr` short-circuits.
        registry.register(AdapterKind::Cardigann, adapter);
        let cache = IndexerProbeCache::new()
            .with_registry(registry)
            .with_ttl(Duration::from_secs(60));

        let entry = cache
            .probe("id-1", AdapterKind::Prowlarr, cfg("id-1"))
            .await;
        assert!(!entry.ok);
        assert!(entry.message.contains("no adapter registered"));
        assert_eq!(
            calls.load(Ordering::SeqCst),
            0,
            "unknown kind never dispatched"
        );
    }
}
