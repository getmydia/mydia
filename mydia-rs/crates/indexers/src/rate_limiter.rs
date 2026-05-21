//! Per-indexer sliding-window rate limiter.
//!
//! Port of `lib/mydia/indexers/rate_limiter.ex`. The Elixir version
//! uses ETS for fast concurrent reads; here we use a `DashMap` keyed by
//! indexer ID. Each entry holds a `Mutex<VecDeque<Instant>>` so the
//! window math runs in O(N-in-window).

use std::collections::VecDeque;
use std::sync::Arc;
use std::time::{Duration, Instant};

use dashmap::DashMap;
use tokio::sync::Mutex;

const WINDOW: Duration = Duration::from_secs(60);

/// Outcome of a [`RateLimiter::check`] call.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RateLimitOutcome {
    /// Request is allowed.
    Ok,
    /// Request would exceed the limit. The caller should wait this many
    /// milliseconds before retrying.
    Limited { retry_after_ms: u64 },
}

/// Sliding-window rate limiter.
///
/// Cheap to clone (one `Arc` per clone) — share via the application
/// state.
#[derive(Clone, Default)]
pub struct RateLimiter {
    inner: Arc<DashMap<String, Arc<Mutex<VecDeque<Instant>>>>>,
}

impl RateLimiter {
    #[must_use]
    pub fn new() -> Self {
        Self {
            inner: Arc::new(DashMap::new()),
        }
    }

    /// Returns [`RateLimitOutcome::Ok`] when the request is allowed. A
    /// `limit` of `None` or `0` disables the check.
    pub async fn check(&self, indexer_id: &str, limit: Option<u32>) -> RateLimitOutcome {
        let Some(limit) = limit else {
            return RateLimitOutcome::Ok;
        };
        if limit == 0 {
            return RateLimitOutcome::Ok;
        }

        let entry = self
            .inner
            .entry(indexer_id.to_owned())
            .or_insert_with(|| Arc::new(Mutex::new(VecDeque::new())))
            .clone();
        let mut guard = entry.lock().await;

        let now = Instant::now();
        // Drop expired entries.
        while let Some(&oldest) = guard.front() {
            if now.duration_since(oldest) >= WINDOW {
                guard.pop_front();
            } else {
                break;
            }
        }

        if (guard.len() as u32) < limit {
            return RateLimitOutcome::Ok;
        }

        let oldest = *guard.front().expect("non-empty after limit check");
        let retry_after = WINDOW.saturating_sub(now.duration_since(oldest));
        RateLimitOutcome::Limited {
            retry_after_ms: retry_after.as_millis() as u64,
        }
    }

    /// Record a request as having happened. Call immediately after a
    /// successful [`check`](Self::check).
    pub async fn record(&self, indexer_id: &str) {
        let entry = self
            .inner
            .entry(indexer_id.to_owned())
            .or_insert_with(|| Arc::new(Mutex::new(VecDeque::new())))
            .clone();
        let mut guard = entry.lock().await;
        guard.push_back(Instant::now());
    }

    /// Number of recorded requests still within the sliding window.
    pub async fn stats(&self, indexer_id: &str) -> u32 {
        let Some(entry) = self.inner.get(indexer_id).map(|r| r.clone()) else {
            return 0;
        };
        let mut guard = entry.lock().await;
        let now = Instant::now();
        while let Some(&oldest) = guard.front() {
            if now.duration_since(oldest) >= WINDOW {
                guard.pop_front();
            } else {
                break;
            }
        }
        guard.len() as u32
    }

    /// Drop all recorded requests for a given indexer.
    pub fn clear(&self, indexer_id: &str) {
        self.inner.remove(indexer_id);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn no_limit_always_ok() {
        let rl = RateLimiter::new();
        assert_eq!(rl.check("i1", None).await, RateLimitOutcome::Ok);
        assert_eq!(rl.check("i1", Some(0)).await, RateLimitOutcome::Ok);
    }

    #[tokio::test]
    async fn allows_up_to_limit_then_throttles() {
        let rl = RateLimiter::new();
        // burst of 3 allowed
        for _ in 0..3 {
            assert_eq!(rl.check("i1", Some(3)).await, RateLimitOutcome::Ok);
            rl.record("i1").await;
        }
        match rl.check("i1", Some(3)).await {
            RateLimitOutcome::Limited { retry_after_ms } => {
                assert!(retry_after_ms > 0);
            }
            RateLimitOutcome::Ok => panic!("expected limited"),
        }
    }

    #[tokio::test]
    async fn isolated_indexers_do_not_interfere() {
        let rl = RateLimiter::new();
        rl.record("a").await;
        rl.record("a").await;
        rl.record("a").await;
        assert_eq!(rl.stats("a").await, 3);
        assert_eq!(rl.stats("b").await, 0);
        assert_eq!(rl.check("b", Some(1)).await, RateLimitOutcome::Ok);
    }

    #[tokio::test]
    async fn clear_drops_recorded_requests() {
        let rl = RateLimiter::new();
        rl.record("x").await;
        rl.record("x").await;
        rl.clear("x");
        assert_eq!(rl.stats("x").await, 0);
    }
}
