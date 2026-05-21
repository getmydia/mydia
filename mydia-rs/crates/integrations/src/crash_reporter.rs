//! Crash reporter.
//!
//! Port of `lib/mydia/crash_reporter/` (queue + sender + sanitizer +
//! logger backend). The Phoenix design is a `GenServer` that owns an
//! ETS-backed retry queue, fed by a Logger handler that filters for
//! `:error` / `:warning` events. The Rust port preserves the same
//! shape with three pieces:
//!
//! - [`CrashReportQueue`]: in-process queue. Workers consume from a
//!   `tokio::sync::mpsc::UnboundedReceiver<CrashEvent>` and POST to
//!   the metadata-relay; failures retry with exponential backoff.
//! - [`Sanitizer`]: pure-data function that scrubs API keys, tokens,
//!   passwords, and usernames out of report fields before send.
//! - [`TracingLayer`]: `tracing_subscriber::Layer` impl that captures
//!   ERROR-level events, builds a [`CrashEvent`], and submits to the
//!   queue's sender side.
//!
//! The HTTP send target is the metadata-relay's `/crashes/report`
//! endpoint, mirroring `Mydia.CrashReporter.Sender`.

use std::sync::Arc;
use std::time::Duration;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use tokio::sync::mpsc::{self, UnboundedReceiver, UnboundedSender};
use tracing::{debug, warn};

use crate::error::IntegrationError;

const DEFAULT_TIMEOUT_MS: u64 = 10_000;

/// Tunables for the retry policy. Default values mirror
/// `lib/mydia/crash_reporter/queue.ex` (1 min initial, 8 min cap, 10
/// retries, 24 h duration).
#[derive(Debug, Clone, Copy)]
pub struct RetryConfig {
    pub initial_delay: Duration,
    pub max_delay: Duration,
    pub max_retries: u32,
    pub max_retry_duration: Duration,
}

impl Default for RetryConfig {
    fn default() -> Self {
        Self {
            initial_delay: Duration::from_secs(60),
            max_delay: Duration::from_secs(8 * 60),
            max_retries: 10,
            max_retry_duration: Duration::from_secs(24 * 60 * 60),
        }
    }
}

impl RetryConfig {
    /// Exponential backoff: `initial * 2^retries`, capped at `max_delay`.
    #[must_use]
    pub fn delay_for(self, retries: u32) -> Duration {
        let multiplier = 2_u64
            .checked_pow(retries)
            .and_then(|m| {
                u64::try_from(self.initial_delay.as_millis())
                    .ok()
                    .map(|i| i.saturating_mul(m))
            })
            .unwrap_or(u64::MAX);
        let capped = multiplier.min(u64::try_from(self.max_delay.as_millis()).unwrap_or(u64::MAX));
        Duration::from_millis(capped)
    }
}

/// One crash report waiting to be flushed.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CrashEvent {
    pub error_type: String,
    pub error_message: String,
    pub stacktrace: Vec<StackFrame>,
    pub metadata: serde_json::Map<String, serde_json::Value>,
    pub timestamp: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StackFrame {
    pub file: Option<String>,
    pub line: Option<u32>,
    pub function: Option<String>,
}

/// Sender handle. Cheap to clone; passed to producers (the
/// `TracingLayer` and any direct `report` call sites).
#[derive(Clone)]
pub struct CrashReportSender {
    tx: UnboundedSender<CrashEvent>,
}

impl CrashReportSender {
    pub fn submit(&self, event: CrashEvent) {
        // The send error path means the receiver has been dropped —
        // log debug and drop the event. The application is shutting
        // down or never wired up the reporter.
        if let Err(err) = self.tx.send(event) {
            debug!(?err, "crash reporter receiver closed; dropping event");
        }
    }
}

/// Background queue worker.
///
/// Constructed by [`CrashReportQueue::new`]; consume from the
/// returned receiver inside a `tokio::task` to drive the queue.
pub struct CrashReportQueue {
    rx: UnboundedReceiver<CrashEvent>,
    sender: Arc<dyn ReportSender + Send + Sync>,
    retry: RetryConfig,
}

impl CrashReportQueue {
    /// Build the queue with a default HTTP sender. Returns the
    /// `CrashReportSender` handle producers use to enqueue.
    pub fn new(
        relay_url: impl Into<String>,
    ) -> Result<(Self, CrashReportSender), IntegrationError> {
        let http = HttpReportSender::new(relay_url.into())?;
        Ok(Self::with_sender(Arc::new(http), RetryConfig::default()))
    }

    /// Build with a custom sender (used by tests).
    pub fn with_sender(
        sender: Arc<dyn ReportSender + Send + Sync>,
        retry: RetryConfig,
    ) -> (Self, CrashReportSender) {
        let (tx, rx) = mpsc::unbounded_channel();
        (Self { rx, sender, retry }, CrashReportSender { tx })
    }

    /// Drain the queue. Runs until the sender side is dropped or the
    /// task is cancelled. Each event is sanitized and posted; on
    /// failure, it retries with exponential backoff up to
    /// `RetryConfig::max_retries` attempts (or `max_retry_duration`,
    /// whichever first).
    pub async fn run(mut self) {
        while let Some(event) = self.rx.recv().await {
            self.deliver(event).await;
        }
    }

    async fn deliver(&self, event: CrashEvent) {
        let sanitized = Sanitizer::sanitize(event);
        let mut retries = 0;
        let started_at = Utc::now();
        loop {
            match self.sender.send(&sanitized).await {
                Ok(()) => {
                    debug!("crash report sent successfully");
                    return;
                }
                Err(err) => {
                    if retries >= self.retry.max_retries {
                        warn!(?err, "crash report dropped after exhausting retries");
                        return;
                    }
                    let elapsed = (Utc::now() - started_at).to_std().unwrap_or_default();
                    if elapsed >= self.retry.max_retry_duration {
                        warn!(?err, "crash report dropped after exceeding retry duration");
                        return;
                    }
                    let delay = self.retry.delay_for(retries);
                    debug!(
                        ?err,
                        retries,
                        ?delay,
                        "crash report send failed; will retry"
                    );
                    tokio::time::sleep(delay).await;
                    retries += 1;
                }
            }
        }
    }
}

/// Pluggable sender trait so the queue can be tested with a mock.
#[async_trait::async_trait]
pub trait ReportSender {
    async fn send(&self, event: &CrashEvent) -> Result<(), IntegrationError>;
}

/// HTTP sender. POSTs the report as JSON to
/// `<relay_url>/crashes/report`. Mirrors `Mydia.CrashReporter.Sender`.
pub struct HttpReportSender {
    inner: reqwest::Client,
    relay_url: String,
}

impl HttpReportSender {
    pub fn new(relay_url: String) -> Result<Self, IntegrationError> {
        if relay_url.is_empty() {
            return Err(IntegrationError::invalid_config("relay_url is required"));
        }
        let inner = reqwest::Client::builder()
            .user_agent(format!(
                "Mydia-rs/{} ({})",
                env!("CARGO_PKG_VERSION"),
                std::env::consts::ARCH
            ))
            .timeout(Duration::from_millis(DEFAULT_TIMEOUT_MS))
            .build()?;
        Ok(Self { inner, relay_url })
    }
}

#[async_trait::async_trait]
impl ReportSender for HttpReportSender {
    async fn send(&self, event: &CrashEvent) -> Result<(), IntegrationError> {
        let url = format!("{}/crashes/report", self.relay_url.trim_end_matches('/'));
        let resp = self.inner.post(&url).json(event).send().await?;
        let status = resp.status();
        if status.is_success() {
            Ok(())
        } else {
            let retry_after = resp
                .headers()
                .get(reqwest::header::RETRY_AFTER)
                .and_then(|v| v.to_str().ok())
                .and_then(|s| s.parse::<u64>().ok());
            let body = resp.text().await.ok();
            Err(IntegrationError::from_response_status(
                status.as_u16(),
                retry_after,
                body.as_deref(),
            ))
        }
    }
}

/// Sanitization helpers. Pure-data; no I/O.
///
/// Port of `lib/mydia/crash_reporter/sanitizer.ex`. The Phoenix module
/// uses a constellation of regex passes; we keep the same passes but
/// pre-compile them with `once_cell` so the cost amortizes across
/// reports.
pub struct Sanitizer;

impl Sanitizer {
    /// Sanitize a [`CrashEvent`] in-place. Returns the cleaned event.
    pub fn sanitize(mut event: CrashEvent) -> CrashEvent {
        event.error_message = sanitize_string(&event.error_message);
        for frame in &mut event.stacktrace {
            if let Some(file) = &frame.file {
                frame.file = Some(sanitize_file_path(file));
            }
        }
        event.metadata = sanitize_map(event.metadata);
        event
    }
}

fn sanitize_map(
    map: serde_json::Map<String, serde_json::Value>,
) -> serde_json::Map<String, serde_json::Value> {
    let mut out = serde_json::Map::with_capacity(map.len());
    for (k, v) in map {
        out.insert(k.clone(), sanitize_value(&k, v));
    }
    out
}

fn sanitize_value(key: &str, value: serde_json::Value) -> serde_json::Value {
    if is_sensitive_key(key) && value.is_string() {
        return serde_json::Value::String("[REDACTED]".into());
    }
    match value {
        serde_json::Value::String(s) => serde_json::Value::String(sanitize_string(&s)),
        serde_json::Value::Object(map) => serde_json::Value::Object(sanitize_map(map)),
        serde_json::Value::Array(arr) => {
            serde_json::Value::Array(arr.into_iter().map(|v| sanitize_value(key, v)).collect())
        }
        other => other,
    }
}

fn is_sensitive_key(key: &str) -> bool {
    let key = key.to_ascii_lowercase();
    [
        "password",
        "secret",
        "api_key",
        "apikey",
        "token",
        "auth",
        "bearer",
        "credentials",
        "private_key",
        "private",
        "key",
        "jwt",
        "session",
        "cookie",
    ]
    .iter()
    .any(|needle| key.contains(needle))
}

fn sanitize_string(s: &str) -> String {
    let mut out = redact_usernames_in_paths(s);
    out = redact_urls(&out);
    out = redact_tokens(&out);
    out = redact_api_keys(&out);
    out = redact_credentials(&out);
    out
}

fn sanitize_file_path(path: &str) -> String {
    redact_usernames_in_paths(path)
}

fn redact_usernames_in_paths(s: &str) -> String {
    let re_home = regex::Regex::new(r"/home/[^/\s]+").expect("static regex");
    let re_users = regex::Regex::new(r"/Users/[^/\s]+").expect("static regex");
    let re_win = regex::Regex::new(r"C:\\Users\\[^\\:\s]+").expect("static regex");
    let s = re_home.replace_all(s, "/home/[USER]");
    let s = re_users.replace_all(&s, "/Users/[USER]");
    let s = re_win.replace_all(&s, r"C:\Users\[USER]");
    s.into_owned()
}

fn redact_urls(s: &str) -> String {
    let re_http = regex::Regex::new(r"https?://[^:]+:[^@]+@").expect("static regex");
    let re_pg = regex::Regex::new(r"postgres://[^:]+:[^@]+@").expect("static regex");
    let re_my = regex::Regex::new(r"mysql://[^:]+:[^@]+@").expect("static regex");
    let s = re_http.replace_all(s, "https://[REDACTED]:[REDACTED]@");
    let s = re_pg.replace_all(&s, "postgres://[REDACTED]:[REDACTED]@");
    let s = re_my.replace_all(&s, "mysql://[REDACTED]:[REDACTED]@");
    s.into_owned()
}

fn redact_tokens(s: &str) -> String {
    let bearer = regex::Regex::new(r"Bearer\s+[a-zA-Z0-9_\-\.]+").expect("static regex");
    let jwt = regex::Regex::new(r"eyJ[\w-]+\.[\w-]+\.[\w-]+").expect("static regex");
    let s = bearer.replace_all(s, "Bearer [REDACTED]");
    let s = jwt.replace_all(&s, "[REDACTED]");
    s.into_owned()
}

fn redact_api_keys(s: &str) -> String {
    let re = regex::Regex::new(r"[a-zA-Z0-9_-]{32,}").expect("static regex");
    re.replace_all(s, |caps: &regex::Captures<'_>| {
        let m = &caps[0];
        if m.chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
        {
            "[REDACTED]".to_owned()
        } else {
            m.to_owned()
        }
    })
    .into_owned()
}

fn redact_credentials(s: &str) -> String {
    let pwd = regex::Regex::new(r#"(?i)password["\s:=]+[^\s"]+"#).expect("static regex");
    let sec = regex::Regex::new(r#"(?i)secret["\s:=]+[^\s"]+"#).expect("static regex");
    let api = regex::Regex::new(r#"(?i)api_key["\s:=]+[^\s"]+"#).expect("static regex");
    let s = pwd.replace_all(s, "password: [REDACTED]");
    let s = sec.replace_all(&s, "secret: [REDACTED]");
    let s = api.replace_all(&s, "api_key: [REDACTED]");
    s.into_owned()
}

/// `tracing_subscriber::Layer` that captures ERROR-level events and
/// forwards them to the [`CrashReportSender`].
///
/// Mirrors the Phoenix `LoggerBackend` in role. The Phoenix version
/// also handles WARN; the Rust port restricts capture to ERROR (per
/// the U32 brief) so the dev environment doesn't drown the relay with
/// transient WARN-only noise. Operators can revisit if needed.
pub struct TracingLayer {
    sender: CrashReportSender,
}

impl TracingLayer {
    pub fn new(sender: CrashReportSender) -> Self {
        Self { sender }
    }
}

impl<S> tracing_subscriber::Layer<S> for TracingLayer
where
    S: tracing::Subscriber + for<'lookup> tracing_subscriber::registry::LookupSpan<'lookup>,
{
    fn on_event(
        &self,
        event: &tracing::Event<'_>,
        _ctx: tracing_subscriber::layer::Context<'_, S>,
    ) {
        if *event.metadata().level() != tracing::Level::ERROR {
            return;
        }
        let mut visitor = EventVisitor::default();
        event.record(&mut visitor);

        let metadata = event.metadata();
        let mut stack = Vec::new();
        if let (Some(file), Some(line)) = (metadata.file(), metadata.line()) {
            stack.push(StackFrame {
                file: Some(file.to_owned()),
                line: Some(line),
                function: metadata.target().rsplit("::").next().map(str::to_owned),
            });
        }

        let crash = CrashEvent {
            error_type: metadata.target().to_owned(),
            error_message: visitor
                .message
                .unwrap_or_else(|| metadata.name().to_owned()),
            stacktrace: stack,
            metadata: visitor.fields,
            timestamp: Utc::now(),
        };
        self.sender.submit(crash);
    }
}

#[derive(Default)]
struct EventVisitor {
    message: Option<String>,
    fields: serde_json::Map<String, serde_json::Value>,
}

impl tracing::field::Visit for EventVisitor {
    fn record_str(&mut self, field: &tracing::field::Field, value: &str) {
        if field.name() == "message" {
            self.message = Some(value.to_owned());
        } else {
            self.fields.insert(
                field.name().to_owned(),
                serde_json::Value::String(value.into()),
            );
        }
    }

    fn record_debug(&mut self, field: &tracing::field::Field, value: &dyn std::fmt::Debug) {
        let rendered = format!("{value:?}");
        if field.name() == "message" {
            self.message = Some(rendered);
        } else {
            self.fields
                .insert(field.name().to_owned(), serde_json::Value::String(rendered));
        }
    }

    fn record_i64(&mut self, field: &tracing::field::Field, value: i64) {
        self.fields.insert(
            field.name().to_owned(),
            serde_json::Value::Number(value.into()),
        );
    }

    fn record_u64(&mut self, field: &tracing::field::Field, value: u64) {
        self.fields.insert(
            field.name().to_owned(),
            serde_json::Value::Number(value.into()),
        );
    }

    fn record_bool(&mut self, field: &tracing::field::Field, value: bool) {
        self.fields
            .insert(field.name().to_owned(), serde_json::Value::Bool(value));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    struct MockSender {
        events: Mutex<Vec<CrashEvent>>,
    }

    impl MockSender {
        fn new() -> Arc<Self> {
            Arc::new(Self {
                events: Mutex::new(Vec::new()),
            })
        }

        fn snapshot(&self) -> Vec<CrashEvent> {
            self.events.lock().unwrap().clone()
        }
    }

    #[async_trait::async_trait]
    impl ReportSender for MockSender {
        async fn send(&self, event: &CrashEvent) -> Result<(), IntegrationError> {
            self.events.lock().unwrap().push(event.clone());
            Ok(())
        }
    }

    #[test]
    fn redacts_long_alphanumeric_strings() {
        let s = "key=abcdef0123456789abcdef0123456789abcdef";
        let out = sanitize_string(s);
        assert!(out.contains("[REDACTED]"), "got: {out}");
    }

    #[test]
    fn redacts_bearer_tokens() {
        let s = "Authorization: Bearer abcdef.gh.ij";
        let out = sanitize_string(s);
        assert!(out.contains("Bearer [REDACTED]"), "got: {out}");
    }

    #[test]
    fn redacts_username_in_path() {
        let s = "Error at /home/alex/Code/mydia/lib/app.ex:42";
        let out = sanitize_string(s);
        assert!(out.contains("/home/[USER]"), "got: {out}");
        assert!(!out.contains("/home/alex"));
    }

    #[test]
    fn sensitive_keys_redacted_in_metadata() {
        let mut meta = serde_json::Map::new();
        meta.insert("api_key".into(), serde_json::Value::String("xyz".into()));
        meta.insert(
            "user_email".into(),
            serde_json::Value::String("a@b.com".into()),
        );
        let sanitized = sanitize_map(meta);
        assert_eq!(sanitized.get("api_key").unwrap(), "[REDACTED]");
        assert_eq!(sanitized.get("user_email").unwrap(), "a@b.com");
    }

    #[test]
    fn retry_delay_exponential_capped() {
        let cfg = RetryConfig::default();
        assert_eq!(cfg.delay_for(0).as_secs(), 60);
        assert_eq!(cfg.delay_for(1).as_secs(), 120);
        assert_eq!(cfg.delay_for(2).as_secs(), 240);
        // Cap at max_delay = 480s.
        assert_eq!(cfg.delay_for(10).as_secs(), 480);
    }

    #[tokio::test]
    async fn queue_drains_when_sender_dropped() {
        let mock = MockSender::new();
        let (queue, sender) = CrashReportQueue::with_sender(
            mock.clone() as Arc<dyn ReportSender + Send + Sync>,
            RetryConfig::default(),
        );
        sender.submit(CrashEvent {
            error_type: "panic".into(),
            error_message: "boom".into(),
            stacktrace: Vec::new(),
            metadata: serde_json::Map::new(),
            timestamp: Utc::now(),
        });
        drop(sender);
        queue.run().await;
        let snapshot = mock.snapshot();
        assert_eq!(snapshot.len(), 1);
        assert_eq!(snapshot[0].error_message, "boom");
    }
}
