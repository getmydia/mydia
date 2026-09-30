//! on-schedule: resolve the server, run one budgeted sync tick, report it.

use crate::endpoint;
use crate::host::Host;
use crate::http::{PlexError, PluginConfig};
use crate::store;
use crate::sync::{self, Counts, SyncError};
use crate::time;
use mydia_plugin_sdk::types::{SyncRunReport, SyncRunStatus};
use serde_json::json;

/// The host kills on-schedule at 60 s. Stop starting new work at 45 s so the
/// last chunk's cursors are always written.
pub const BUDGET_MS: u64 = 45_000;

pub fn run(host: &mut dyn Host, config_json: &str) -> Result<String, String> {
    let cfg = PluginConfig::parse(config_json);
    if !cfg.sync_enabled() {
        return Ok(json!({"skipped": "sync_disabled"}).to_string());
    }
    let started = host.now();
    let deadline_ms = host.elapsed_ms() + BUDGET_MS;

    let resolved = endpoint::resolve(host, &cfg).and_then(|base| {
        Ok((
            base,
            endpoint::server_link(host)?,
            endpoint::owner_link(host)?,
        ))
    });
    let (base, server_link, owner_link) = match resolved {
        Ok(r) => r,
        // Health reports this with a Reconnect action. A failed run every 30
        // minutes would only bury the real history.
        Err(PlexError::Unauthorized) => {
            host.log(
                "warn",
                "plex: the server rejected the instance credential; waiting for reconnect",
            );
            return Ok(json!({"skipped": "unauthorized"}).to_string());
        }
        Err(e) => {
            report(
                host,
                started,
                SyncRunStatus::Error,
                Counts::default(),
                Some(e.message()),
            );
            return Ok(json!({"skipped": "unreachable"}).to_string());
        }
    };
    // check-health has no config, so it probes whatever address was last good.
    let _ = store::put_json(
        host,
        store::ENDPOINT_CURRENT,
        &json!({"url": base, "checked_at": started}),
    );

    match sync::run_tick(host, &base, &server_link, &owner_link, &cfg, deadline_ms) {
        Ok(out) => {
            let status =
                if out.counts.errors > 0 || !out.unauthorized_links.is_empty() || !out.complete {
                    SyncRunStatus::Partial
                } else {
                    SyncRunStatus::Ok
                };
            let message = (!out.complete).then(|| "continuing next tick".to_string());
            report(host, started, status, out.counts, message);
            Ok(json!({
                "pulled": out.counts.pulled,
                "pushed": out.counts.pushed,
                "skipped": out.counts.skipped,
                "errors": out.counts.errors,
                "not_found": out.counts.not_found,
                "complete": out.complete,
            })
            .to_string())
        }
        Err(SyncError::Unauthorized) => {
            host.log(
                "warn",
                "plex: the server rejected the instance credential mid-crawl",
            );
            Ok(json!({"skipped": "unauthorized"}).to_string())
        }
        // An Err makes the host scheduler back off exponentially.
        Err(SyncError::Failed(msg)) => {
            report(
                host,
                started,
                SyncRunStatus::Error,
                Counts::default(),
                Some(msg.clone()),
            );
            Err(format!("plex sync failed: {msg}"))
        }
    }
}

fn report(
    host: &mut dyn Host,
    started: i64,
    status: SyncRunStatus,
    c: Counts,
    message: Option<String>,
) {
    let run = SyncRunReport {
        started_at: time::to_rfc3339(started),
        finished_at: time::to_rfc3339(host.now()),
        status,
        pulled: c.pulled,
        pushed: c.pushed,
        skipped: c.skipped + c.not_found,
        errors: c.errors,
        message,
    };
    if let Err(e) = host.report_sync_run(&run) {
        host.log("warn", &format!("plex: report-sync-run failed: {e:?}"));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::host::fake::FakeHost;
    use mydia_plugin_sdk::types::LinkRole;

    const NOW: i64 = 1_767_225_600;
    const B: &str = "http://plex.test";

    fn cfg(sync: &str) -> String {
        format!(r#"{{"instance_id":"I1","url":"{B}","sync_watched":"{sync}"}}"#)
    }

    fn host() -> FakeHost {
        let mut h = FakeHost::new();
        h.now_value = NOW;
        h.with_link("owner", LinkRole::Owner, None, None);
        h
    }

    #[test]
    fn sync_disabled_does_nothing() {
        let mut h = host();
        assert_eq!(
            run(&mut h, &cfg("off")).unwrap(),
            r#"{"skipped":"sync_disabled"}"#
        );
        assert!(h.sent.is_empty());
        assert!(h.runs.is_empty());
    }

    #[test]
    fn an_instance_401_skips_without_a_failed_run() {
        let mut h = host();
        h.respond("GET", &format!("{B}/library/sections"), 401, "");
        let out: serde_json::Value =
            serde_json::from_str(&run(&mut h, &cfg("on")).unwrap()).unwrap();
        assert_eq!(out["skipped"], "unauthorized");
        assert!(h.runs.is_empty());
    }

    #[test]
    fn an_unreachable_server_records_an_error_run() {
        let mut h = host();
        let out: serde_json::Value =
            serde_json::from_str(&run(&mut h, &cfg("on")).unwrap()).unwrap();
        assert_eq!(out["skipped"], "unreachable");
        assert_eq!(h.runs.len(), 1);
        assert_eq!(h.runs[0].status, SyncRunStatus::Error);
    }

    #[test]
    fn a_completed_tick_reports_one_run_and_remembers_the_endpoint() {
        let mut h = host();
        h.respond(
            "GET",
            &format!("{B}/library/sections"),
            200,
            r#"{"MediaContainer":{"Directory":[]}}"#,
        );
        let out: serde_json::Value =
            serde_json::from_str(&run(&mut h, &cfg("on")).unwrap()).unwrap();
        assert_eq!(out["complete"], true);
        assert_eq!(h.runs.len(), 1);
        assert_eq!(h.runs[0].status, SyncRunStatus::Ok);
        assert_eq!(h.runs[0].started_at, "2026-01-01T00:00:00Z");
        let current: serde_json::Value =
            serde_json::from_str(&h.kv[store::ENDPOINT_CURRENT]).unwrap();
        assert_eq!(current["url"], B);
    }
}
