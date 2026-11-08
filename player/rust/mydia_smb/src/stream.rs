//! Loopback HTTP/1.1 range server that mpv plays SMB files through.
//!
//! `open` registers a token for `(account, target, credentials, path)` and
//! returns `http://127.0.0.1:<port>/smb/<token>`. The token is 128 random
//! bits and carries no path or credential, so nothing sensitive reaches
//! mpv's logs. The first request for a token opens the SMB file; later
//! requests reuse the handle until it has been idle for a minute.
//!
//! Tokens go when their account closes, and after 12 hours unused.
//!
//! A body streams in 1 MiB positioned reads. The reader task keeps one chunk
//! in flight and one buffered ahead of the consumer. If a read
//! fails, the file is opened again once through the pool (which has already
//! dropped the dead connection) and the response resumes where it was. A
//! second failure ends the response: before the headers that is a 502, after
//! them the connection is aborted, and mpv retries the range.

use std::collections::HashMap;
use std::convert::Infallible;
use std::io;
use std::net::{Ipv4Addr, SocketAddr};
use std::pin::Pin;
use std::sync::atomic::{AtomicU16, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::task::{Context, Poll};
use std::time::{Duration, Instant};

use bytes::Bytes;
use hyper::body::{Body, Frame, Incoming, SizeHint};
use hyper::header::{HeaderValue, ACCEPT_RANGES, CONTENT_LENGTH, CONTENT_RANGE, CONTENT_TYPE};
use hyper::{Method, Request, Response, StatusCode};
use hyper_util::rt::TokioIo;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc;
use tokio::task::JoinHandle;

use crate::range::parse_range;
use crate::{Heal, SmbClient, SmbCredentials, SmbError, SmbFile, SmbTarget};

/// Size of one positioned read.
const CHUNK: u64 = 1024 * 1024;
/// A token unused this long is forgotten.
const TOKEN_TTL: Duration = Duration::from_hours(12);
/// An open file handle unused this long is closed (the token stays), so a
/// finished playback does not pin its pooled connection for 12 hours.
const FILE_IDLE: Duration = Duration::from_mins(1);
/// How often expired tokens and idle handles are swept.
const SWEEP_PERIOD: Duration = Duration::from_secs(30);
/// Error text for a read whose token was closed with its account.
const ACCOUNT_CLOSED: &str = "account closed";
/// Bound on the liveness probe `heal` makes against its own listener.
const HEAL_PROBE_TIMEOUT: Duration = Duration::from_secs(1);

/// What a token stands for.
#[derive(Clone)]
struct TokenTarget {
    account: String,
    target: SmbTarget,
    creds: SmbCredentials,
    path: String,
}

struct TokenEntry {
    info: TokenTarget,
    last_used: Instant,
    file: Option<Arc<SmbFile>>,
    /// Responses still streaming for this token. A token in use never
    /// expires; its idle time starts when the last response ends.
    active: usize,
}

/// Issued tokens. Time is passed in, so expiry is testable without a clock.
#[derive(Default)]
struct TokenTable {
    entries: HashMap<String, TokenEntry>,
}

impl TokenTable {
    fn insert(&mut self, token: String, info: TokenTarget, now: Instant) {
        self.entries.insert(
            token,
            TokenEntry {
                info,
                last_used: now,
                file: None,
                active: 0,
            },
        );
    }

    /// Look a token up and mark it used. An expired token is removed.
    fn get(&mut self, token: &str, now: Instant) -> Option<(TokenTarget, Option<Arc<SmbFile>>)> {
        let entry = self.entries.get_mut(token)?;
        if entry.active == 0 && now.saturating_duration_since(entry.last_used) > TOKEN_TTL {
            self.entries.remove(token);
            return None;
        }
        entry.last_used = now;
        Some((entry.info.clone(), entry.file.clone()))
    }

    /// A response for `token` started streaming.
    fn begin(&mut self, token: &str) {
        if let Some(entry) = self.entries.get_mut(token) {
            entry.active += 1;
        }
    }

    /// A response for `token` ended: its idle time starts now.
    fn end(&mut self, token: &str, now: Instant) {
        if let Some(entry) = self.entries.get_mut(token) {
            entry.active = entry.active.saturating_sub(1);
            entry.last_used = now;
        }
    }

    /// Cache an open handle for a token that is still issued. `false` when
    /// the token is gone.
    fn set_file(&mut self, token: &str, file: Arc<SmbFile>) -> bool {
        let Some(entry) = self.entries.get_mut(token) else {
            return false;
        };
        entry.file = Some(file);
        true
    }

    /// Forget an account's tokens, returning each distinct target and login
    /// they referenced so the caller can close those connections.
    fn remove_account(&mut self, account: &str) -> Vec<(SmbTarget, SmbCredentials)> {
        let mut removed: Vec<(SmbTarget, SmbCredentials)> = Vec::new();
        self.entries.retain(|_, e| {
            if e.info.account != account {
                return true;
            }
            let pair = (e.info.target.clone(), e.info.creds.clone());
            if !removed.contains(&pair) {
                removed.push(pair);
            }
            false
        });
        removed
    }

    fn contains(&self, token: &str) -> bool {
        self.entries.contains_key(token)
    }

    /// Forget expired tokens and close handles idle past [`FILE_IDLE`]. A
    /// token with a response still streaming is neither.
    fn sweep(&mut self, now: Instant) {
        self.entries.retain(|_, e| {
            if e.active > 0 {
                return true;
            }
            let idle = now.saturating_duration_since(e.last_used);
            if idle > FILE_IDLE {
                e.file = None;
            }
            idle <= TOKEN_TTL
        });
    }
}

/// State shared by the server handle and every connection task.
struct Shared {
    client: Arc<SmbClient>,
    tokens: Mutex<TokenTable>,
    port: AtomicU16,
    #[cfg(feature = "test-introspection")]
    min_read_offset: std::sync::atomic::AtomicU64,
    #[cfg(feature = "test-introspection")]
    active_readers: std::sync::atomic::AtomicUsize,
}

/// The loopback range server. Dropping it stops accepting connections.
pub struct StreamServer {
    shared: Arc<Shared>,
    accept: Mutex<Option<JoinHandle<()>>>,
    heal_lock: tokio::sync::Mutex<()>,
    sweeper: JoinHandle<()>,
}

impl StreamServer {
    /// Bind `127.0.0.1:0` and start serving. Must be called inside a tokio
    /// runtime: the accept loop and every connection run on it.
    pub async fn start(client: Arc<SmbClient>) -> io::Result<Arc<Self>> {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await?;
        let port = listener.local_addr()?.port();
        let shared = Arc::new(Shared {
            client,
            tokens: Mutex::new(TokenTable::default()),
            port: AtomicU16::new(port),
            #[cfg(feature = "test-introspection")]
            min_read_offset: std::sync::atomic::AtomicU64::new(u64::MAX),
            #[cfg(feature = "test-introspection")]
            active_readers: std::sync::atomic::AtomicUsize::new(0),
        });
        let accept = tokio::spawn(accept_loop(listener, shared.clone()));
        let sweeper = tokio::spawn(sweep_loop(Arc::downgrade(&shared)));
        Ok(Arc::new(Self {
            shared,
            accept: Mutex::new(Some(accept)),
            heal_lock: tokio::sync::Mutex::new(()),
            sweeper,
        }))
    }

    /// The port currently listened on.
    pub fn port(&self) -> u16 {
        self.shared.port.load(Ordering::Acquire)
    }

    /// Issue a token for a file and return its URL. Nothing is opened yet.
    /// Fails only if the OS cannot supply random bytes for the token.
    pub fn open(
        &self,
        account: &str,
        t: SmbTarget,
        c: SmbCredentials,
        path: &str,
    ) -> Result<String, SmbError> {
        let token = new_token()?;
        let info = TokenTarget {
            account: account.to_string(),
            target: t,
            creds: c,
            path: path.to_string(),
        };
        if let Ok(mut tokens) = self.shared.tokens.lock() {
            tokens.insert(token.clone(), info, Instant::now());
        }
        Ok(format!("http://127.0.0.1:{}/smb/{token}", self.port()))
    }

    /// Forget every token issued for an account, closing their handles.
    pub fn close_account(&self, account: &str) {
        let removed = self
            .shared
            .tokens
            .lock()
            .map(|mut tokens| tokens.remove_account(account))
            .unwrap_or_default();
        for (target, creds) in removed {
            self.shared.client.close(&target, &creds);
        }
    }

    /// Make sure something still accepts on our port (an OS can tear a
    /// listener down while the app is suspended). If nothing does, listen
    /// again: on the same port if it is free, so issued URLs keep working,
    /// otherwise on a new one.
    pub async fn heal(&self) -> io::Result<Heal> {
        // One heal at a time: two racing would each spawn an accept task and
        // the loser's handle would be overwritten, leaving it orphaned.
        let _one_at_a_time = self.heal_lock.lock().await;
        let port = self.port();
        let alive = self
            .accept
            .lock()
            .is_ok_and(|a| a.as_ref().is_some_and(|h| !h.is_finished()));
        if alive && accepts(port).await {
            return Ok(Heal::Healthy);
        }
        self.stop_accepting_and_wait().await;
        let (listener, heal) = match TcpListener::bind((Ipv4Addr::LOCALHOST, port)).await {
            Ok(l) => (l, Heal::ReboundSamePort),
            Err(_) => (
                TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await?,
                Heal::ReboundNewPort,
            ),
        };
        let new_port = listener.local_addr()?.port();
        self.shared.port.store(new_port, Ordering::Release);
        let handle = tokio::spawn(accept_loop(listener, self.shared.clone()));
        if let Ok(mut accept) = self.accept.lock() {
            *accept = Some(handle);
        }
        Ok(heal)
    }

    fn take_accept_task(&self) -> Option<JoinHandle<()>> {
        let handle = self.accept.lock().ok()?.take()?;
        handle.abort();
        Some(handle)
    }

    fn stop_accepting(&self) {
        self.take_accept_task();
    }

    /// Abort the accept loop and wait until its listener is closed, so the
    /// port is free to bind again.
    async fn stop_accepting_and_wait(&self) {
        if let Some(handle) = self.take_accept_task() {
            let _ = handle.await;
        }
    }

    /// Lowest file offset any read has started at (`u64::MAX` before any).
    #[cfg(feature = "test-introspection")]
    pub fn min_read_offset(&self) -> u64 {
        self.shared.min_read_offset.load(Ordering::Acquire)
    }

    /// Response bodies whose reader task is still running.
    #[cfg(feature = "test-introspection")]
    pub fn active_readers(&self) -> usize {
        self.shared.active_readers.load(Ordering::Acquire)
    }

    /// Drop the listener, as an OS might while the app is suspended.
    #[cfg(feature = "test-introspection")]
    pub async fn stop_listener(&self) {
        self.stop_accepting_and_wait().await;
    }
}

impl Drop for StreamServer {
    fn drop(&mut self) {
        self.stop_accepting();
        self.sweeper.abort();
    }
}

/// Whether a loopback connect to `port` succeeds.
async fn accepts(port: u16) -> bool {
    let addr = SocketAddr::from((Ipv4Addr::LOCALHOST, port));
    matches!(
        tokio::time::timeout(HEAL_PROBE_TIMEOUT, TcpStream::connect(addr)).await,
        Ok(Ok(_))
    )
}

/// 128 random bits as 32 lowercase hex characters. Fails when the OS has no
/// randomness to give: a guessable token would expose the file, so there is
/// no weaker fallback.
fn new_token() -> Result<String, SmbError> {
    let mut raw = [0_u8; 16];
    getrandom::fill(&mut raw)
        .map_err(|e| SmbError::Other(format!("no OS randomness for a stream token: {e}")))?;
    Ok(raw.iter().fold(String::with_capacity(32), |mut s, b| {
        use std::fmt::Write as _;
        let _ = write!(s, "{b:02x}");
        s
    }))
}

async fn accept_loop(listener: TcpListener, shared: Arc<Shared>) {
    loop {
        let Ok((stream, _)) = listener.accept().await else {
            // Transient accept errors (EMFILE and the like): back off and
            // keep going. A listener torn down for good is noticed by heal.
            tokio::time::sleep(Duration::from_millis(50)).await;
            continue;
        };
        let shared = shared.clone();
        tokio::spawn(async move {
            let service = hyper::service::service_fn(move |req| {
                let shared = shared.clone();
                async move { Ok::<_, Infallible>(respond(&shared, &req).await) }
            });
            // A client hanging up mid-body is routine (mpv seeks), not an
            // error worth reporting.
            let _ = hyper::server::conn::http1::Builder::new()
                .serve_connection(TokioIo::new(stream), service)
                .await;
        });
    }
}

async fn sweep_loop(shared: Weak<Shared>) {
    loop {
        tokio::time::sleep(SWEEP_PERIOD).await;
        let Some(shared) = shared.upgrade() else {
            break;
        };
        if let Ok(mut tokens) = shared.tokens.lock() {
            tokens.sweep(Instant::now());
        }
        drop(shared);
    }
}

/// Marks a token in use for as long as one response holds it, so the sweep
/// never expires a token under a body that is still streaming (a playback
/// paused for longer than [`TOKEN_TTL`] holds its connection open).
struct ActiveResponse {
    shared: Arc<Shared>,
    token: String,
}

impl ActiveResponse {
    fn new(shared: &Arc<Shared>, token: &str) -> Self {
        if let Ok(mut tokens) = shared.tokens.lock() {
            tokens.begin(token);
        }
        Self {
            shared: shared.clone(),
            token: token.to_string(),
        }
    }
}

impl Drop for ActiveResponse {
    fn drop(&mut self) {
        if let Ok(mut tokens) = self.shared.tokens.lock() {
            tokens.end(&self.token, Instant::now());
        }
    }
}

/// One request's view of its token: where to reopen from, the handle in use,
/// and whether its single reconnect has been spent.
struct Cursor {
    shared: Arc<Shared>,
    token: String,
    info: TokenTarget,
    file: Arc<SmbFile>,
    reconnected: bool,
    _active: ActiveResponse,
}

impl Cursor {
    /// Read up to `len` bytes at `offset`, reopening the file once on error.
    async fn read(&mut self, offset: u64, len: u64) -> Result<Bytes, SmbError> {
        #[cfg(feature = "test-introspection")]
        self.shared
            .min_read_offset
            .fetch_min(offset, Ordering::AcqRel);
        // A closed account's body ends at the next chunk, and never
        // reconnects on the account's behalf.
        if !token_issued(&self.shared, &self.token) {
            return Err(SmbError::Other(ACCOUNT_CLOSED.to_string()));
        }
        let len = usize::try_from(len).unwrap_or(usize::MAX);
        match self.file.read_at(offset, len).await {
            Ok(data) => Ok(Bytes::from(data)),
            Err(_) if !self.reconnected => {
                self.reconnected = true;
                self.file = open_file(&self.shared, &self.token, &self.info).await?;
                self.file.read_at(offset, len).await.map(Bytes::from)
            }
            Err(e) => Err(e),
        }
    }
}

/// Open the token's file through the pool and cache the handle.
async fn open_file(
    shared: &Shared,
    token: &str,
    info: &TokenTarget,
) -> Result<Arc<SmbFile>, SmbError> {
    if !token_issued(shared, token) {
        return Err(SmbError::Other(ACCOUNT_CLOSED.to_string()));
    }
    let file = Arc::new(
        shared
            .client
            .open(&info.target, &info.creds, &info.path)
            .await?,
    );
    let cached = shared
        .tokens
        .lock()
        .is_ok_and(|mut tokens| tokens.set_file(token, file.clone()));
    if !cached {
        // The account closed while we were connecting: undo the connection
        // made on its behalf.
        drop(file);
        shared.client.close(&info.target, &info.creds);
        return Err(SmbError::Other(ACCOUNT_CLOSED.to_string()));
    }
    Ok(file)
}

/// Whether a token is still issued (not closed with its account).
fn token_issued(shared: &Shared, token: &str) -> bool {
    shared.tokens.lock().is_ok_and(|t| t.contains(token))
}

async fn respond(shared: &Arc<Shared>, req: &Request<Incoming>) -> Response<StreamBody> {
    let head = match *req.method() {
        Method::GET => false,
        Method::HEAD => true,
        _ => return status(StatusCode::METHOD_NOT_ALLOWED),
    };
    let Some(token) = req
        .uri()
        .path()
        .strip_prefix("/smb/")
        .filter(|t| t.len() == 32 && t.bytes().all(|b| b.is_ascii_hexdigit()))
    else {
        return status(StatusCode::NOT_FOUND);
    };
    let found = shared
        .tokens
        .lock()
        .ok()
        .and_then(|mut t| t.get(token, Instant::now()));
    let Some((info, cached)) = found else {
        return status(StatusCode::NOT_FOUND);
    };
    let active = ActiveResponse::new(shared, token);

    // Opening counts as the request's one reconnect only when a cached
    // handle existed and failed; a first open gets a retry of its own.
    let mut reconnected = false;
    let file = match cached {
        Some(f) => f,
        None => match open_file(shared, token, &info).await {
            Ok(f) => f,
            Err(SmbError::Unreachable(_)) => {
                reconnected = true;
                match open_file(shared, token, &info).await {
                    Ok(f) => f,
                    Err(e) => return smb_failure(&e),
                }
            }
            Err(e) => return smb_failure(&e),
        },
    };
    let size = file.size();
    let mut cursor = Cursor {
        shared: shared.clone(),
        token: token.to_string(),
        info,
        file,
        reconnected,
        _active: active,
    };

    let range = req
        .headers()
        .get(hyper::header::RANGE)
        .and_then(|v| v.to_str().ok())
        .and_then(parse_range);
    let (code, first, last) = match range {
        None => (StatusCode::OK, 0, size.checked_sub(1)),
        Some(r) => {
            let Some((a, b)) = r.resolve(size) else {
                let mut resp = status(StatusCode::RANGE_NOT_SATISFIABLE);
                insert(&mut resp, CONTENT_RANGE, &format!("bytes */{size}"));
                return resp;
            };
            (StatusCode::PARTIAL_CONTENT, a, Some(b))
        }
    };
    let len = last.map_or(0, |b| b - first + 1);

    let body = if head || len == 0 {
        StreamBody::empty()
    } else {
        // Read the first chunk before committing to a status, so a dead
        // share is a 502 rather than a truncated 200.
        let first_chunk = match cursor.read(first, len.min(CHUNK)).await {
            Ok(data) if !data.is_empty() => data,
            Ok(_) => return status(StatusCode::BAD_GATEWAY),
            Err(e) => return smb_failure(&e),
        };
        let next = first + first_chunk.len() as u64;
        let end = first + len;
        let rx = (next < end).then(|| spawn_reader(cursor, next, end));
        StreamBody {
            first: Some(first_chunk),
            rx,
        }
    };

    let mut resp = Response::new(body);
    *resp.status_mut() = code;
    insert(&mut resp, CONTENT_TYPE, "application/octet-stream");
    insert(&mut resp, ACCEPT_RANGES, "bytes");
    insert(&mut resp, CONTENT_LENGTH, &len.to_string());
    if let (StatusCode::PARTIAL_CONTENT, Some(b)) = (code, last) {
        insert(
            &mut resp,
            CONTENT_RANGE,
            &format!("bytes {first}-{b}/{size}"),
        );
    }
    resp
}

/// Read `[offset, end)` into a channel of one chunk, so the next chunk is
/// being fetched while hyper writes the current one. The task ends when the
/// range is done, on a second read failure, or as soon as the response body
/// is dropped (the client hung up), even mid-read: a read stalled on a dead
/// share, or its reconnect, is abandoned rather than left holding the file
/// and the connection until it times out.
fn spawn_reader(
    mut cursor: Cursor,
    mut offset: u64,
    end: u64,
) -> mpsc::Receiver<io::Result<Bytes>> {
    let (tx, rx) = mpsc::channel(1);
    tokio::spawn(async move {
        #[cfg(feature = "test-introspection")]
        let _guard = ReaderGuard::new(&cursor.shared);
        while offset < end {
            let read = cursor.read(offset, (end - offset).min(CHUNK));
            let result = tokio::select! {
                r = read => r,
                () = tx.closed() => break,
            };
            let chunk = match result {
                Ok(data) if !data.is_empty() => data,
                // The file shrank under us: end the body short.
                Ok(_) => {
                    let _ = tx
                        .send(Err(io::Error::from(io::ErrorKind::UnexpectedEof)))
                        .await;
                    break;
                }
                Err(e) => {
                    let _ = tx.send(Err(io::Error::other(e))).await;
                    break;
                }
            };
            offset += chunk.len() as u64;
            if tx.send(Ok(chunk)).await.is_err() {
                break;
            }
        }
    });
    rx
}

#[cfg(feature = "test-introspection")]
struct ReaderGuard(Arc<Shared>);

#[cfg(feature = "test-introspection")]
impl ReaderGuard {
    fn new(shared: &Arc<Shared>) -> Self {
        shared.active_readers.fetch_add(1, Ordering::AcqRel);
        Self(shared.clone())
    }
}

#[cfg(feature = "test-introspection")]
impl Drop for ReaderGuard {
    fn drop(&mut self) {
        self.0.active_readers.fetch_sub(1, Ordering::AcqRel);
    }
}

fn status(code: StatusCode) -> Response<StreamBody> {
    let mut resp = Response::new(StreamBody::empty());
    *resp.status_mut() = code;
    insert(&mut resp, CONTENT_LENGTH, "0");
    resp
}

fn smb_failure(e: &SmbError) -> Response<StreamBody> {
    match e {
        SmbError::NotFound => status(StatusCode::NOT_FOUND),
        _ => status(StatusCode::BAD_GATEWAY),
    }
}

fn insert(resp: &mut Response<StreamBody>, name: hyper::header::HeaderName, value: &str) {
    if let Ok(v) = HeaderValue::from_str(value) {
        resp.headers_mut().insert(name, v);
    }
}

/// A response body: an optional first chunk, then whatever the reader sends.
/// An error frame makes hyper abort the connection, which is how a body cut
/// short reaches the client.
struct StreamBody {
    first: Option<Bytes>,
    rx: Option<mpsc::Receiver<io::Result<Bytes>>>,
}

impl StreamBody {
    fn empty() -> Self {
        Self {
            first: None,
            rx: None,
        }
    }
}

impl Body for StreamBody {
    type Data = Bytes;
    type Error = io::Error;

    fn poll_frame(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Bytes>, io::Error>>> {
        if let Some(first) = self.first.take() {
            return Poll::Ready(Some(Ok(Frame::data(first))));
        }
        match self.rx.as_mut() {
            None => Poll::Ready(None),
            Some(rx) => rx
                .poll_recv(cx)
                .map(|item| item.map(|r| r.map(Frame::data))),
        }
    }

    fn is_end_stream(&self) -> bool {
        self.first.is_none() && self.rx.is_none()
    }

    fn size_hint(&self) -> SizeHint {
        if self.is_end_stream() {
            SizeHint::with_exact(0)
        } else {
            SizeHint::default()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn info(account: &str) -> TokenTarget {
        TokenTarget {
            account: account.to_string(),
            target: SmbTarget {
                host: "nas".to_string(),
                port: 445,
                share: "media".to_string(),
            },
            creds: SmbCredentials {
                user: String::new(),
                password: String::new(),
                domain: None,
            },
            path: "/a.mkv".to_string(),
        }
    }

    #[test]
    fn token_expires_after_12h_unused() {
        let t0 = Instant::now();
        let mut table = TokenTable::default();
        table.insert("tok".to_string(), info("acct"), t0);
        let used = t0 + TOKEN_TTL;
        assert!(
            table.get("tok", used).is_some(),
            "exactly 12 h is still fresh"
        );
        // That use reset the clock.
        let later = used + TOKEN_TTL;
        assert!(table.get("tok", later).is_some());
        assert!(table
            .get("tok", later + TOKEN_TTL + Duration::from_secs(1))
            .is_none());
        // Gone for good, not just refused once.
        assert!(table.entries.is_empty());
    }

    #[test]
    fn sweep_drops_expired_tokens_only() {
        let t0 = Instant::now();
        let mut table = TokenTable::default();
        table.insert("old".to_string(), info("acct"), t0);
        table.insert(
            "new".to_string(),
            info("acct"),
            t0 + Duration::from_hours(1),
        );
        table.sweep(t0 + TOKEN_TTL + Duration::from_secs(1));
        assert!(!table.entries.contains_key("old"));
        assert!(table.entries.contains_key("new"));
    }

    #[test]
    fn a_streaming_token_outlives_the_ttl_and_idles_from_its_end() {
        let t0 = Instant::now();
        let mut table = TokenTable::default();
        table.insert("tok".to_string(), info("acct"), t0);
        table.begin("tok");
        let long_after = t0 + TOKEN_TTL * 2;
        table.sweep(long_after);
        assert!(table.contains("tok"), "swept under a live response");
        assert!(table.get("tok", long_after).is_some());
        table.end("tok", long_after);
        table.sweep(long_after + TOKEN_TTL);
        assert!(table.contains("tok"), "idle time starts at the end");
        table.sweep(long_after + TOKEN_TTL + Duration::from_secs(1));
        assert!(!table.contains("tok"));
    }

    #[test]
    fn remove_account_keeps_other_accounts() {
        let now = Instant::now();
        let mut table = TokenTable::default();
        table.insert("a".to_string(), info("one"), now);
        table.insert("b".to_string(), info("two"), now);
        table.insert("c".to_string(), info("one"), now);
        let removed = table.remove_account("one");
        assert!(table.get("a", now).is_none());
        assert!(!table.contains("c"));
        assert!(table.get("b", now).is_some());
        // Two tokens on the same target and login close one connection.
        let one = info("one");
        assert_eq!(removed, vec![(one.target, one.creds)]);
    }

    #[test]
    fn tokens_are_32_hex_and_distinct() {
        let a = new_token().unwrap();
        let b = new_token().unwrap();
        assert_eq!(a.len(), 32);
        assert!(a
            .bytes()
            .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()));
        assert_ne!(a, b);
    }
}
