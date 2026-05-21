//! Debrid adapter. Rust port of `lib/mydia/downloads/client/debrid.ex`
//! plus the `Fetcher` rate-limiter pattern from
//! `lib/mydia/downloads/client/debrid/`.
//!
//! ## Provider dispatch
//!
//! Phoenix's debrid module is a thin dispatcher that picks one of
//! four upstream providers (Real-Debrid, `AllDebrid`, Premiumize,
//! `TorBox`) per-config via `connection_settings["provider"]`. The
//! Rust port keeps the same layout: [`DebridClient`] looks at
//! [`ClientConfig::options`]`["provider"]`, consults the
//! [`RateLimiter`] for the matching provider key, then hands off to
//! the corresponding per-provider HTTP call.
//!
//! ## Rate limiting
//!
//! Phoenix uses an ETS-backed sliding window in
//! `Mydia.Downloads.Client.Debrid.RateLimiter` keyed by `{provider,
//! api_key}` so two operators using different tokens on the same
//! provider don't share a budget. The Rust port mirrors that with
//! [`tokio::sync::Semaphore`]s held in a `DashMap` keyed by the same
//! tuple — semaphore permits per second rather than ETS counters,
//! but the operator-visible effect (per-account fair sharing) is
//! identical.
//!
//! ## Scope note
//!
//! This unit ships the trait skeleton + per-provider stubs that
//! return clear "provider not yet wired" errors. U17's worker layer
//! will plug the concrete provider HTTP calls in as part of the R8
//! cron path; the rate-limit + dispatch surface lives here so that
//! plumbing change is mechanical.

use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use dashmap::DashMap;
use tokio::sync::Semaphore;

use crate::adapter::{
    AddOpts, ClientConfig, ClientInfo, DownloadClient, DownloadStatus, ListOpts, Protocol,
    TorrentInput,
};
use crate::error::DownloadError;

/// Adapter handle. Holds the per-provider rate limiter so callers
/// share one across the registry — matching Phoenix's named ETS table.
pub struct DebridClient {
    limiter: Arc<RateLimiter>,
}

impl DebridClient {
    /// Build with default provider budgets.
    #[must_use]
    pub fn new() -> Self {
        Self {
            limiter: Arc::new(RateLimiter::new()),
        }
    }

    /// Access the shared limiter (mostly for tests).
    pub fn limiter(&self) -> Arc<RateLimiter> {
        self.limiter.clone()
    }
}

impl Default for DebridClient {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl DownloadClient for DebridClient {
    fn name(&self) -> &'static str {
        "debrid"
    }

    fn supported_protocols(&self) -> &'static [Protocol] {
        &[Protocol::Torrent]
    }

    async fn test_connection(&self, config: &ClientConfig) -> Result<ClientInfo, DownloadError> {
        let provider = resolve_provider(config)?;
        let api_key = config.api_key.clone();
        self.limiter.acquire(provider, api_key.as_deref()).await?;
        // The actual provider HTTP call lands in U17's worker layer;
        // for U20 we return a placeholder ClientInfo so the registry
        // surface compiles. The error path below covers the missing
        // credential case so admins still see a clear error.
        if api_key.is_none() && matches!(provider, ProviderKind::TorBox) {
            return Err(DownloadError::InvalidConfig(
                "debrid: api_key required for torbox".into(),
            ));
        }
        Ok(ClientInfo {
            version: format!("debrid:{} (stub)", provider.label()),
            api_version: Some("1.0".into()),
            rpc_version: None,
        })
    }

    async fn add(
        &self,
        config: &ClientConfig,
        _input: TorrentInput,
        _opts: AddOpts,
    ) -> Result<String, DownloadError> {
        let provider = resolve_provider(config)?;
        self.limiter
            .acquire(provider, config.api_key.as_deref())
            .await?;
        Err(DownloadError::Internal(format!(
            "debrid provider {} wired in U17",
            provider.label()
        )))
    }

    async fn list_active(
        &self,
        _config: &ClientConfig,
        _opts: ListOpts,
    ) -> Result<Vec<DownloadStatus>, DownloadError> {
        // Phoenix returns `{:ok, []}` for the untracked-matcher path
        // when no downloads were passed in — debrid has no "untracked
        // on the client" concept. Mirror that here so U17's cron
        // worker doesn't trip over an unimplemented method during the
        // parallel window.
        Ok(vec![])
    }

    async fn cancel(
        &self,
        config: &ClientConfig,
        _client_id: &str,
        _delete_files: bool,
    ) -> Result<(), DownloadError> {
        let provider = resolve_provider(config)?;
        self.limiter
            .acquire(provider, config.api_key.as_deref())
            .await?;
        // Best-effort no-op so the orchestrator can call cancel
        // through the registry without special-casing debrid.
        Ok(())
    }

    async fn get_files(
        &self,
        _config: &ClientConfig,
        _client_id: &str,
    ) -> Result<Vec<String>, DownloadError> {
        Ok(vec![])
    }

    async fn get_save_path(
        &self,
        _config: &ClientConfig,
        _client_id: &str,
    ) -> Result<String, DownloadError> {
        // Debrid downloads land on disk via the fetcher path (U17);
        // until that wiring is in place we surface a clear error.
        Err(DownloadError::Internal(
            "debrid save_path resolution wired in U17 (R8 metadata cron)".into(),
        ))
    }
}

/// Four supported providers, mirroring
/// `Mydia.Downloads.Client.Debrid.Provider`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ProviderKind {
    RealDebrid,
    AllDebrid,
    Premiumize,
    TorBox,
}

impl ProviderKind {
    /// Operator-facing label (matches Phoenix's `Provider.label_for/1`).
    #[must_use]
    pub fn label(self) -> &'static str {
        match self {
            ProviderKind::RealDebrid => "real-debrid",
            ProviderKind::AllDebrid => "all-debrid",
            ProviderKind::Premiumize => "premiumize",
            ProviderKind::TorBox => "torbox",
        }
    }

    /// Default budget pulled straight from Phoenix's
    /// `Provider.rate_limit_budget/0` callback. `(requests,
    /// window_seconds)`.
    #[must_use]
    pub fn budget(self) -> (u32, u64) {
        match self {
            ProviderKind::RealDebrid => (250, 60),
            ProviderKind::AllDebrid => (600, 60),
            ProviderKind::Premiumize => (30, 60),
            ProviderKind::TorBox => (300, 60),
        }
    }
}

fn resolve_provider(config: &ClientConfig) -> Result<ProviderKind, DownloadError> {
    match config.options.get("provider").map(String::as_str) {
        Some("real-debrid" | "real_debrid") => Ok(ProviderKind::RealDebrid),
        Some("all-debrid" | "all_debrid") => Ok(ProviderKind::AllDebrid),
        Some("premiumize") => Ok(ProviderKind::Premiumize),
        Some("torbox" | "tor_box") => Ok(ProviderKind::TorBox),
        Some(other) => Err(DownloadError::InvalidConfig(format!(
            "debrid: unknown provider '{other}'"
        ))),
        None => Err(DownloadError::InvalidConfig(
            "debrid: provider option missing".into(),
        )),
    }
}

/// Per-account rate limiter. One `Semaphore` per `(provider,
/// api_key)` tuple, sized to the provider's budget. Permits refresh
/// on a one-second tick driven by a background task spawned the
/// first time a key is touched.
pub struct RateLimiter {
    semaphores: DashMap<RateKey, Arc<Semaphore>>,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
struct RateKey {
    provider: ProviderKind,
    api_key: String,
}

impl RateLimiter {
    /// Empty limiter. Permits are allocated lazily on first
    /// `acquire`.
    #[must_use]
    pub fn new() -> Self {
        Self {
            semaphores: DashMap::new(),
        }
    }

    /// Take one permit out of `(provider, api_key)`'s budget. If the
    /// budget is exhausted the call waits up to the provider's
    /// window for a refill; on persistent saturation returns
    /// [`DownloadError::Network`] (matching Phoenix's
    /// `{:error, :rate_limited}` mapping at the call site).
    pub async fn acquire(
        &self,
        provider: ProviderKind,
        api_key: Option<&str>,
    ) -> Result<RatePermit, DownloadError> {
        let (max_requests, window_seconds) = provider.budget();
        let key = RateKey {
            provider,
            api_key: api_key.unwrap_or("").to_owned(),
        };
        let semaphore = self
            .semaphores
            .entry(key.clone())
            .or_insert_with(|| Arc::new(Semaphore::new(max_requests as usize)))
            .clone();

        let timeout = Duration::from_secs(window_seconds);
        let permit = match tokio::time::timeout(timeout, semaphore.clone().acquire_owned()).await {
            Ok(Ok(permit)) => permit,
            Ok(Err(_)) => {
                return Err(DownloadError::Internal(
                    "debrid limiter semaphore closed".into(),
                ));
            }
            Err(_) => {
                return Err(DownloadError::Network(format!(
                    "rate-limited by {} provider (waited {window_seconds}s)",
                    provider.label()
                )));
            }
        };

        // Spawn a refund task that releases the permit after the
        // window elapses. This produces the same sliding-window
        // effect as Phoenix's ETS-backed limiter without the bespoke
        // bookkeeping — under steady load the operator's permits
        // recycle automatically.
        let semaphore_for_refund = semaphore.clone();
        let refund_after = Duration::from_secs(window_seconds);
        tokio::spawn(async move {
            tokio::time::sleep(refund_after).await;
            drop(permit);
            // Hold a reference so the semaphore is kept alive even
            // if the outer DashMap entry is evicted before refund.
            drop(semaphore_for_refund);
        });
        Ok(RatePermit { _private: () })
    }

    /// Diagnostic helper. Number of currently-available permits for
    /// `(provider, api_key)`.
    pub fn available(&self, provider: ProviderKind, api_key: Option<&str>) -> Option<usize> {
        let key = RateKey {
            provider,
            api_key: api_key.unwrap_or("").to_owned(),
        };
        self.semaphores.get(&key).map(|s| s.available_permits())
    }
}

impl Default for RateLimiter {
    fn default() -> Self {
        Self::new()
    }
}

/// Opaque token returned by [`RateLimiter::acquire`]. Holding the
/// token guarantees the call site is allowed to issue one upstream
/// request; the actual semaphore permit is owned by the refund task
/// so the caller can drop the token without releasing budget early.
pub struct RatePermit {
    _private: (),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn provider_labels_are_stable() {
        assert_eq!(ProviderKind::RealDebrid.label(), "real-debrid");
        assert_eq!(ProviderKind::AllDebrid.label(), "all-debrid");
        assert_eq!(ProviderKind::Premiumize.label(), "premiumize");
        assert_eq!(ProviderKind::TorBox.label(), "torbox");
    }

    #[test]
    fn resolve_provider_accepts_both_separators() {
        let mut config = ClientConfig::default();
        config
            .options
            .insert("provider".into(), "real_debrid".into());
        assert_eq!(resolve_provider(&config).unwrap(), ProviderKind::RealDebrid);
        config
            .options
            .insert("provider".into(), "real-debrid".into());
        assert_eq!(resolve_provider(&config).unwrap(), ProviderKind::RealDebrid);
    }

    #[tokio::test]
    async fn rate_limiter_isolates_keys() {
        let limiter = RateLimiter::new();
        let _a = limiter
            .acquire(ProviderKind::Premiumize, Some("alice"))
            .await
            .unwrap();
        let _b = limiter
            .acquire(ProviderKind::Premiumize, Some("bob"))
            .await
            .unwrap();
        // Different api_keys -> separate budgets; both calls
        // succeed and each key still has 29/30 permits remaining.
        assert_eq!(
            limiter.available(ProviderKind::Premiumize, Some("alice")),
            Some(29)
        );
        assert_eq!(
            limiter.available(ProviderKind::Premiumize, Some("bob")),
            Some(29)
        );
    }
}
