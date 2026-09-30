//! Every host import the plugin uses, behind one trait so module logic can be
//! driven by a scripted fake in native `cargo test`.

use mydia_plugin_sdk::host;
use mydia_plugin_sdk::types::{
    AccountLink, EnsureWatchedResult, HostError, KvEntry, KvPage, LinkStatus, ListRequest,
    ListResult, OutboundRequest, OutboundResponse, RemoteAccount, SyncRunReport, WatchStateTarget,
};

pub trait Host {
    fn http_request(&mut self, req: &OutboundRequest) -> Result<OutboundResponse, HostError>;
    fn link_request(
        &mut self,
        link_id: &str,
        req: &OutboundRequest,
    ) -> Result<OutboundResponse, HostError>;
    fn kv_get(&mut self, key: &str) -> Result<Option<String>, HostError>;
    fn kv_set(&mut self, key: &str, value: &str) -> Result<(), HostError>;
    fn kv_delete(&mut self, key: &str) -> Result<(), HostError>;
    fn kv_list(&mut self, prefix: &str, cursor: Option<&str>) -> Result<KvPage, HostError>;
    fn kv_set_many(&mut self, entries: &[KvEntry]) -> Result<(), HostError>;
    fn links_list(&mut self) -> Result<Vec<AccountLink>, HostError>;
    fn propose_accounts(&mut self, accounts: &[RemoteAccount]) -> Result<(), HostError>;
    fn set_link_token(&mut self, link_id: &str, token: &str) -> Result<(), HostError>;
    fn set_link_status(
        &mut self,
        link_id: &str,
        status: LinkStatus,
        message: Option<&str>,
    ) -> Result<(), HostError>;
    fn set_watch_state(
        &mut self,
        target: &WatchStateTarget,
    ) -> Result<EnsureWatchedResult, HostError>;
    fn data_list(&mut self, req: &ListRequest) -> Result<ListResult, HostError>;
    fn report_sync_run(&mut self, run: &SyncRunReport) -> Result<(), HostError>;
    fn log(&mut self, level: &str, message: &str);
    /// Unix seconds.
    fn now(&mut self) -> i64;
    /// Milliseconds on a monotonic clock, for the 45 s schedule budget.
    fn elapsed_ms(&mut self) -> u64;
}

/// The real imports. Constructed once per export call, so `elapsed_ms` measures
/// the current invocation.
pub struct WasmHost {
    start: std::time::Instant,
}

impl WasmHost {
    pub fn new() -> Self {
        WasmHost {
            start: std::time::Instant::now(),
        }
    }
}

impl Default for WasmHost {
    fn default() -> Self {
        Self::new()
    }
}

impl Host for WasmHost {
    fn http_request(&mut self, req: &OutboundRequest) -> Result<OutboundResponse, HostError> {
        host::http_request(req)
    }

    fn link_request(
        &mut self,
        link_id: &str,
        req: &OutboundRequest,
    ) -> Result<OutboundResponse, HostError> {
        host::link_request(link_id, req)
    }

    fn kv_get(&mut self, key: &str) -> Result<Option<String>, HostError> {
        host::kv_get(key)
    }

    fn kv_set(&mut self, key: &str, value: &str) -> Result<(), HostError> {
        host::kv_set(key, value).map(|_| ())
    }

    fn kv_delete(&mut self, key: &str) -> Result<(), HostError> {
        host::kv_delete(key).map(|_| ())
    }

    fn kv_list(&mut self, prefix: &str, cursor: Option<&str>) -> Result<KvPage, HostError> {
        host::kv_list(prefix, cursor)
    }

    fn kv_set_many(&mut self, entries: &[KvEntry]) -> Result<(), HostError> {
        host::kv_set_many(entries)
    }

    fn links_list(&mut self) -> Result<Vec<AccountLink>, HostError> {
        host::links_list()
    }

    fn propose_accounts(&mut self, accounts: &[RemoteAccount]) -> Result<(), HostError> {
        host::propose_accounts(accounts)
    }

    fn set_link_token(&mut self, link_id: &str, token: &str) -> Result<(), HostError> {
        host::set_link_token(link_id, token)
    }

    fn set_link_status(
        &mut self,
        link_id: &str,
        status: LinkStatus,
        message: Option<&str>,
    ) -> Result<(), HostError> {
        host::set_link_status(link_id, status, message)
    }

    fn set_watch_state(
        &mut self,
        target: &WatchStateTarget,
    ) -> Result<EnsureWatchedResult, HostError> {
        host::set_watch_state(target)
    }

    fn data_list(&mut self, req: &ListRequest) -> Result<ListResult, HostError> {
        host::data_list(req)
    }

    fn report_sync_run(&mut self, run: &SyncRunReport) -> Result<(), HostError> {
        host::report_sync_run(run)
    }

    fn log(&mut self, level: &str, message: &str) {
        host::log(level, message)
    }

    fn now(&mut self) -> i64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0)
    }

    fn elapsed_ms(&mut self) -> u64 {
        self.start.elapsed().as_millis() as u64
    }
}

#[cfg(test)]
pub mod fake {
    use super::Host;
    use mydia_plugin_sdk::types::{
        AccountLink, EnsureWatchedResult, EnsureWatchedStatus, HostError, KvEntry, KvPage,
        LinkRole, LinkStatus, ListRequest, ListResult, OutboundRequest, OutboundResponse,
        RemoteAccount, SyncRunReport, WatchStateTarget,
    };
    use std::collections::{BTreeMap, HashMap, VecDeque};

    /// One recorded outbound call. `link` is `Some(id)` for `link_request`.
    #[derive(Debug, Clone)]
    pub struct Sent {
        pub link: Option<String>,
        pub method: String,
        pub url: String,
        pub headers: Vec<(String, String)>,
        pub body: Option<String>,
    }

    impl Sent {
        pub fn header(&self, name: &str) -> Option<&str> {
            self.headers
                .iter()
                .find(|(k, _)| k.eq_ignore_ascii_case(name))
                .map(|(_, v)| v.as_str())
        }
    }

    #[derive(Default)]
    pub struct FakeHost {
        /// Scripted responses keyed by (METHOD, full URL). Each call pops the
        /// front; the last entry repeats so a stub can answer many times.
        pub responses: HashMap<(String, String), VecDeque<Result<OutboundResponse, HostError>>>,
        /// Responses that apply only to `link_request` with this link id,
        /// consulted before `responses`.
        pub link_responses:
            HashMap<(String, String, String), VecDeque<Result<OutboundResponse, HostError>>>,
        pub sent: Vec<Sent>,
        pub kv: BTreeMap<String, String>,
        pub links: Vec<AccountLink>,
        pub proposed: Vec<Vec<RemoteAccount>>,
        pub tokens: HashMap<String, String>,
        pub statuses: Vec<(String, LinkStatus, Option<String>)>,
        pub watch_writes: Vec<WatchStateTarget>,
        pub data_pages: VecDeque<ListResult>,
        pub data_requests: Vec<ListRequest>,
        pub runs: Vec<SyncRunReport>,
        pub logs: Vec<(String, String)>,
        pub now_value: i64,
        pub elapsed: u64,
    }

    impl FakeHost {
        pub fn new() -> Self {
            FakeHost {
                now_value: 1_750_000_000,
                ..Default::default()
            }
        }

        pub fn respond(&mut self, method: &str, url: &str, status: u16, body: &str) -> &mut Self {
            let resp = OutboundResponse {
                status,
                ok: (200..300).contains(&status),
                body: Some(body.to_string()),
                body_encoding: None,
            };
            self.responses
                .entry((method.to_string(), url.to_string()))
                .or_default()
                .push_back(Ok(resp));
            self
        }

        pub fn respond_link(
            &mut self,
            link: &str,
            method: &str,
            url: &str,
            status: u16,
            body: &str,
        ) -> &mut Self {
            let resp = OutboundResponse {
                status,
                ok: (200..300).contains(&status),
                body: Some(body.to_string()),
                body_encoding: None,
            };
            self.link_responses
                .entry((link.to_string(), method.to_string(), url.to_string()))
                .or_default()
                .push_back(Ok(resp));
            self
        }

        pub fn fail(&mut self, method: &str, url: &str, err: HostError) -> &mut Self {
            self.responses
                .entry((method.to_string(), url.to_string()))
                .or_default()
                .push_back(Err(err));
            self
        }

        pub fn with_link(
            &mut self,
            id: &str,
            role: LinkRole,
            external_id: Option<&str>,
            name: Option<&str>,
        ) -> &mut Self {
            self.links.push(AccountLink {
                id: id.to_string(),
                role,
                user_id: None,
                external_user_id: external_id.map(str::to_string),
                external_username: name.map(str::to_string),
                status: LinkStatus::Active,
            });
            self
        }

        pub fn requests_to(&self, url: &str) -> Vec<&Sent> {
            self.sent.iter().filter(|s| s.url == url).collect()
        }

        fn answer(
            &mut self,
            link: Option<&str>,
            req: &OutboundRequest,
        ) -> Result<OutboundResponse, HostError> {
            self.sent.push(Sent {
                link: link.map(str::to_string),
                method: req.method.clone(),
                url: req.url.clone(),
                headers: req.headers.clone(),
                body: req.body.clone(),
            });
            if let Some(link) = link {
                let lkey = (link.to_string(), req.method.clone(), req.url.clone());
                if let Some(queue) = self.link_responses.get_mut(&lkey) {
                    return if queue.len() > 1 {
                        queue.pop_front().unwrap()
                    } else {
                        queue.front().cloned().unwrap()
                    };
                }
            }
            let key = (req.method.clone(), req.url.clone());
            match self.responses.get_mut(&key) {
                Some(queue) if queue.len() > 1 => queue.pop_front().unwrap(),
                Some(queue) if queue.len() == 1 => queue.front().cloned().unwrap(),
                _ => Err(HostError::Network(format!(
                    "no fake response for {} {}",
                    key.0, key.1
                ))),
            }
        }
    }

    impl Host for FakeHost {
        fn http_request(&mut self, req: &OutboundRequest) -> Result<OutboundResponse, HostError> {
            self.answer(None, req)
        }

        fn link_request(
            &mut self,
            link_id: &str,
            req: &OutboundRequest,
        ) -> Result<OutboundResponse, HostError> {
            self.answer(Some(link_id), req)
        }

        fn kv_get(&mut self, key: &str) -> Result<Option<String>, HostError> {
            Ok(self.kv.get(key).cloned())
        }

        fn kv_set(&mut self, key: &str, value: &str) -> Result<(), HostError> {
            self.kv.insert(key.to_string(), value.to_string());
            Ok(())
        }

        fn kv_delete(&mut self, key: &str) -> Result<(), HostError> {
            self.kv.remove(key);
            Ok(())
        }

        fn kv_list(&mut self, prefix: &str, cursor: Option<&str>) -> Result<KvPage, HostError> {
            let mut entries: Vec<KvEntry> = self
                .kv
                .iter()
                .filter(|(k, _)| k.starts_with(prefix))
                .filter(|(k, _)| cursor.is_none_or(|c| k.as_str() > c))
                .map(|(k, v)| KvEntry {
                    key: k.clone(),
                    value: v.clone(),
                })
                .collect();
            let next_cursor = if entries.len() > 200 {
                entries.truncate(200);
                entries.last().map(|e| e.key.clone())
            } else {
                None
            };
            Ok(KvPage {
                entries,
                next_cursor,
            })
        }

        fn kv_set_many(&mut self, entries: &[KvEntry]) -> Result<(), HostError> {
            for e in entries {
                self.kv.insert(e.key.clone(), e.value.clone());
            }
            Ok(())
        }

        fn links_list(&mut self) -> Result<Vec<AccountLink>, HostError> {
            Ok(self.links.clone())
        }

        fn propose_accounts(&mut self, accounts: &[RemoteAccount]) -> Result<(), HostError> {
            self.proposed.push(accounts.to_vec());
            Ok(())
        }

        fn set_link_token(&mut self, link_id: &str, token: &str) -> Result<(), HostError> {
            self.tokens.insert(link_id.to_string(), token.to_string());
            Ok(())
        }

        fn set_link_status(
            &mut self,
            link_id: &str,
            status: LinkStatus,
            message: Option<&str>,
        ) -> Result<(), HostError> {
            self.statuses
                .push((link_id.to_string(), status, message.map(str::to_string)));
            Ok(())
        }

        fn set_watch_state(
            &mut self,
            target: &WatchStateTarget,
        ) -> Result<EnsureWatchedResult, HostError> {
            self.watch_writes.push(target.clone());
            Ok(EnsureWatchedResult {
                status: EnsureWatchedStatus::Changed,
            })
        }

        fn data_list(&mut self, req: &ListRequest) -> Result<ListResult, HostError> {
            self.data_requests.push(req.clone());
            Ok(self.data_pages.pop_front().unwrap_or(ListResult {
                items: vec![],
                next_cursor: None,
            }))
        }

        fn report_sync_run(&mut self, run: &SyncRunReport) -> Result<(), HostError> {
            self.runs.push(run.clone());
            Ok(())
        }

        fn log(&mut self, level: &str, message: &str) {
            self.logs.push((level.to_string(), message.to_string()));
        }

        fn now(&mut self) -> i64 {
            self.now_value
        }

        fn elapsed_ms(&mut self) -> u64 {
            self.elapsed
        }
    }
}
