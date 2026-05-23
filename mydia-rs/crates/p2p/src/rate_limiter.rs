//! Atomic claim-failure rate limiter.
//!
//! ## Problem
//!
//! The Phoenix port (`lib/mydia/remote_access/claim_rate_limiter.ex`)
//! uses `:ets.update_counter/2` to atomically increment a counter but
//! then issues a separate read for the window start; the
//! "check whether window has expired and conditionally reset" branch
//! is NOT atomic. Under 100 concurrent failures from a single IP the
//! reset can interleave with the increment so the limiter admits
//! more than the configured `max_attempts`.
//!
//! ## Approach
//!
//! Use `dashmap::Entry` API so each `check_and_record` runs under a
//! per-key shard lock. Inside that critical section we (a) consider
//! the window-expired reset, (b) increment, and (c) compare to the
//! threshold. The entire transition is atomic, so N concurrent
//! failures produce at most `max_attempts` Allowed responses.
//!
//! ## Window semantics
//!
//! Matches Phoenix:
//!
//! - 5 attempts per IP per hour by default.
//! - Window starts at the first attempt; subsequent attempts within
//!   the window increment the same counter.
//! - Window expiry: any check that arrives after `window_start +
//!   window` resets the counter to 1 (this attempt) and stamps the
//!   new window start.
//! - Successful claim resets the counter for the IP, so a legit
//!   user does not stay flagged once they get the code right.

use std::sync::Arc;
use std::time::{Duration, Instant};

use dashmap::DashMap;

/// Outcome of [`ClaimRateLimiter::check_and_record_failure`] or
/// [`ClaimRateLimiter::check_only`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RateLimitOutcome {
    /// The attempt is allowed. The caller should proceed with the
    /// claim validation, then call `record_success` if it succeeded
    /// to clear the counter or `record_failure` to bump it.
    Allowed,
    /// The IP has exceeded the threshold within the current window.
    /// The caller should refuse the claim attempt without consulting
    /// the DB.
    Blocked,
}

struct Bucket {
    attempts: u32,
    window_start: Instant,
}

/// Sliding-window-ish rate limiter, keyed on caller-supplied IP /
/// peer identifier.
#[derive(Clone)]
pub struct ClaimRateLimiter {
    inner: Arc<DashMap<String, Bucket>>,
    max_attempts: u32,
    window: Duration,
}

impl ClaimRateLimiter {
    /// Phoenix defaults: 5 attempts per IP per hour. Build with these
    /// for parity with `lib/mydia/remote_access/claim_rate_limiter.ex`.
    pub fn new_default() -> Self {
        Self::new(5, Duration::from_secs(3600))
    }

    pub fn new(max_attempts: u32, window: Duration) -> Self {
        Self {
            inner: Arc::new(DashMap::new()),
            max_attempts,
            window,
        }
    }

    /// Atomically check + record a FAILED attempt.
    ///
    /// This is the safe primitive: call it before running the actual
    /// validation. If it returns [`RateLimitOutcome::Allowed`], the
    /// caller proceeds; on a downstream success call
    /// [`Self::reset`] to clear the slate.
    ///
    /// Concurrent calls for the same IP serialise under the shard
    /// lock so the increment + threshold check is one critical
    /// section. With 100 concurrent failures and `max_attempts = 5`,
    /// exactly 5 calls return `Allowed`.
    pub fn check_and_record_failure(&self, ip: &str) -> RateLimitOutcome {
        // We use `entry()` so the bucket lookup + mutation share one
        // critical section. Calling `get()` followed by `insert()`
        // would re-introduce the Phoenix-side race.
        let mut entry = self.inner.entry(ip.to_string()).or_insert_with(|| Bucket {
            attempts: 0,
            window_start: Instant::now(),
        });

        let now = Instant::now();
        // Sliding behaviour: any check past the window resets.
        if now.duration_since(entry.window_start) >= self.window {
            entry.attempts = 0;
            entry.window_start = now;
        }

        if entry.attempts >= self.max_attempts {
            return RateLimitOutcome::Blocked;
        }

        entry.attempts += 1;
        RateLimitOutcome::Allowed
    }

    /// Read-only check: returns [`RateLimitOutcome::Blocked`] when
    /// the IP is over the threshold WITHOUT incrementing.
    ///
    /// Useful for the "before we even bother with the DB" pre-flight,
    /// but the call site must follow up with
    /// [`Self::check_and_record_failure`] before declaring the
    /// attempt allowed, otherwise concurrent callers race.
    pub fn check_only(&self, ip: &str) -> RateLimitOutcome {
        let Some(entry) = self.inner.get(ip) else {
            return RateLimitOutcome::Allowed;
        };
        if Instant::now().duration_since(entry.window_start) >= self.window {
            return RateLimitOutcome::Allowed;
        }
        if entry.attempts >= self.max_attempts {
            RateLimitOutcome::Blocked
        } else {
            RateLimitOutcome::Allowed
        }
    }

    /// Clear the counter for an IP. Call after a successful claim
    /// validation so a user who recovers from a typo does not stay
    /// flagged.
    pub fn reset(&self, ip: &str) {
        self.inner.remove(ip);
    }

    /// Number of IPs currently tracked. Mostly for tests.
    pub fn tracked_ips(&self) -> usize {
        self.inner.len()
    }

    /// Drop entries whose window has fully expired. Cheap O(n) sweep;
    /// the production caller wires it to a tokio timer (every 10
    /// minutes by default, matching Phoenix). Tests can call it
    /// directly.
    pub fn cleanup_expired(&self) {
        let now = Instant::now();
        let window = self.window;
        self.inner
            .retain(|_, bucket| now.duration_since(bucket.window_start) < window);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc as StdArc;
    use std::thread;

    #[test]
    fn within_threshold_allows() {
        let limiter = ClaimRateLimiter::new(5, Duration::from_secs(60));
        for _ in 0..5 {
            assert_eq!(
                limiter.check_and_record_failure("1.2.3.4"),
                RateLimitOutcome::Allowed
            );
        }
    }

    #[test]
    fn over_threshold_blocks() {
        let limiter = ClaimRateLimiter::new(3, Duration::from_secs(60));
        for _ in 0..3 {
            assert_eq!(
                limiter.check_and_record_failure("1.2.3.4"),
                RateLimitOutcome::Allowed
            );
        }
        assert_eq!(
            limiter.check_and_record_failure("1.2.3.4"),
            RateLimitOutcome::Blocked
        );
        assert_eq!(
            limiter.check_and_record_failure("1.2.3.4"),
            RateLimitOutcome::Blocked
        );
    }

    #[test]
    fn reset_clears_the_counter() {
        let limiter = ClaimRateLimiter::new(2, Duration::from_secs(60));
        limiter.check_and_record_failure("1.2.3.4");
        limiter.check_and_record_failure("1.2.3.4");
        assert_eq!(
            limiter.check_and_record_failure("1.2.3.4"),
            RateLimitOutcome::Blocked
        );
        limiter.reset("1.2.3.4");
        assert_eq!(
            limiter.check_and_record_failure("1.2.3.4"),
            RateLimitOutcome::Allowed
        );
    }

    #[test]
    fn per_ip_isolation() {
        let limiter = ClaimRateLimiter::new(2, Duration::from_secs(60));
        limiter.check_and_record_failure("1.1.1.1");
        limiter.check_and_record_failure("1.1.1.1");
        assert_eq!(
            limiter.check_and_record_failure("1.1.1.1"),
            RateLimitOutcome::Blocked
        );
        // Different IP. fresh bucket.
        assert_eq!(
            limiter.check_and_record_failure("2.2.2.2"),
            RateLimitOutcome::Allowed
        );
    }

    /// The load-bearing test for this module: 100 concurrent failures
    /// from one IP with `max_attempts = 5` must produce EXACTLY 5
    /// `Allowed` responses, never N+k. This is the race the Phoenix
    /// implementation can lose; we must not.
    #[test]
    fn concurrent_failures_admit_exactly_max_attempts() {
        let limiter = StdArc::new(ClaimRateLimiter::new(5, Duration::from_secs(60)));
        let mut handles = Vec::new();
        let counter = StdArc::new(std::sync::Mutex::new(0u32));

        for _ in 0..100 {
            let limiter = limiter.clone();
            let counter = counter.clone();
            handles.push(thread::spawn(move || {
                if limiter.check_and_record_failure("attacker.example") == RateLimitOutcome::Allowed
                {
                    *counter.lock().unwrap() += 1;
                }
            }));
        }
        for h in handles {
            h.join().unwrap();
        }

        let admitted = *counter.lock().unwrap();
        assert_eq!(
            admitted, 5,
            "expected exactly 5 admitted attempts, got {admitted}"
        );
    }

    #[test]
    fn expired_window_resets_atomically() {
        let limiter = ClaimRateLimiter::new(2, Duration::from_millis(5));
        for _ in 0..2 {
            limiter.check_and_record_failure("1.2.3.4");
        }
        assert_eq!(
            limiter.check_and_record_failure("1.2.3.4"),
            RateLimitOutcome::Blocked
        );
        std::thread::sleep(Duration::from_millis(10));
        assert_eq!(
            limiter.check_and_record_failure("1.2.3.4"),
            RateLimitOutcome::Allowed
        );
    }

    #[test]
    fn cleanup_drops_expired_entries() {
        let limiter = ClaimRateLimiter::new(5, Duration::from_millis(5));
        limiter.check_and_record_failure("a");
        limiter.check_and_record_failure("b");
        assert_eq!(limiter.tracked_ips(), 2);
        std::thread::sleep(Duration::from_millis(10));
        limiter.cleanup_expired();
        assert_eq!(limiter.tracked_ips(), 0);
    }
}
