//! Health-check primitives for indexers.
//!
//! Port of `lib/mydia/indexers/health.ex`. The Elixir module owns a
//! GenServer that periodically pings every configured indexer and
//! caches the result in ETS; for the Rust port that scheduling is left
//! to the U17 worker layer. This module ships the data types plus a
//! small in-memory cache so resolvers / admin UIs can read the latest
//! status without re-running the probe.

use std::sync::Arc;
use std::time::{Duration, Instant};

use chrono::{DateTime, Utc};
use dashmap::DashMap;
use serde::{Deserialize, Serialize};

/// Cardigann definition `health_status` column values.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum HealthStatus {
    Healthy,
    Degraded,
    Unhealthy,
    Unknown,
}

/// Outcome of a single health probe.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HealthResult {
    pub status: HealthStatus,
    pub checked_at: DateTime<Utc>,
    pub details: serde_json::Value,
    pub error: Option<String>,
}

impl HealthResult {
    #[must_use]
    pub fn healthy(details: serde_json::Value) -> Self {
        Self {
            status: HealthStatus::Healthy,
            checked_at: Utc::now(),
            details,
            error: None,
        }
    }

    #[must_use]
    pub fn unhealthy(message: impl Into<String>) -> Self {
        Self {
            status: HealthStatus::Unhealthy,
            checked_at: Utc::now(),
            details: serde_json::Value::Null,
            error: Some(message.into()),
        }
    }
}

/// TTL-cached in-memory store. Wire the U17 worker to call [`record`]
/// after each probe; resolvers query via [`get`].
#[derive(Clone, Default)]
pub struct HealthCache {
    inner: Arc<DashMap<String, CacheEntry>>,
    ttl: Duration,
    failures: Arc<DashMap<String, u32>>,
}

#[derive(Debug, Clone)]
struct CacheEntry {
    result: HealthResult,
    cached_at: Instant,
}

impl HealthCache {
    /// 5-minute TTL — matches Elixir `@cache_ttl`.
    #[must_use]
    pub fn new() -> Self {
        Self::with_ttl(Duration::from_secs(5 * 60))
    }

    #[must_use]
    pub fn with_ttl(ttl: Duration) -> Self {
        Self {
            inner: Arc::new(DashMap::new()),
            failures: Arc::new(DashMap::new()),
            ttl,
        }
    }

    /// Returns the cached result for `indexer_id` when still fresh.
    #[must_use]
    pub fn get(&self, indexer_id: &str) -> Option<HealthResult> {
        let entry = self.inner.get(indexer_id)?;
        if entry.cached_at.elapsed() < self.ttl {
            Some(entry.result.clone())
        } else {
            None
        }
    }

    /// Store the result and update the failure counter accordingly.
    pub fn record(&self, indexer_id: &str, result: HealthResult) {
        match result.status {
            HealthStatus::Healthy => {
                self.failures.remove(indexer_id);
            }
            HealthStatus::Unhealthy => {
                *self.failures.entry(indexer_id.to_owned()).or_insert(0) += 1;
            }
            _ => {}
        }
        self.inner.insert(
            indexer_id.to_owned(),
            CacheEntry {
                result,
                cached_at: Instant::now(),
            },
        );
    }

    /// Consecutive-failure count, mirroring `RateLimiter.get_failure_count/1`.
    #[must_use]
    pub fn failure_count(&self, indexer_id: &str) -> u32 {
        self.failures
            .get(indexer_id)
            .map_or(0, |entry| *entry.value())
    }

    /// Drop cached state for one indexer.
    pub fn clear(&self, indexer_id: &str) {
        self.inner.remove(indexer_id);
        self.failures.remove(indexer_id);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ttl_evicts_stale_entries() {
        let cache = HealthCache::with_ttl(Duration::from_millis(1));
        cache.record("i", HealthResult::healthy(serde_json::json!({"v": 1})));
        std::thread::sleep(Duration::from_millis(10));
        assert!(cache.get("i").is_none());
    }

    #[test]
    fn failure_counter_resets_on_recovery() {
        let cache = HealthCache::new();
        cache.record("i", HealthResult::unhealthy("nope"));
        cache.record("i", HealthResult::unhealthy("nope again"));
        assert_eq!(cache.failure_count("i"), 2);
        cache.record("i", HealthResult::healthy(serde_json::json!({})));
        assert_eq!(cache.failure_count("i"), 0);
    }
}
