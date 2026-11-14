//! Serves file reads from paired players: the bytes behind a shared Files
//! library.
//!
//! A viewer reads a file as an `HlsStream` request whose session id is
//! `peerfile:<account id>` and whose path is the host's file path, base64url
//! without padding. This module is the host's side of that, and the security
//! boundary of the feature:
//!
//! - Only peers in the member allowlist Dart pushes in are answered (403).
//! - Rust never decides which paths are readable. It asks Dart for a grant per
//!   `(account id, path)`, and Dart grants only indexed files and their
//!   sidecars. A path Dart does not share is 404, so a read can only ever
//!   touch what Dart handed back. A path it shares but whose backend failed,
//!   or a grant request Dart never answered, is 502: the file is there, the
//!   host just cannot reach it right now.
//! - Each peer gets [`READS_PER_PEER`] concurrent reads. Further reads wait.
//!
//! Everything here is `pub(crate)`: `flutter_rust_bridge` generates Dart
//! bindings for every `pub` item in the crate, and none of this is Dart's.
//! `P2pHost` carries the FFI surface.

use crate::FlutterPeerFileGrantRequest;
use base64::Engine as _;
use flutter_rust_bridge::frb;
use mydia_p2p_core::runtime::time::timeout;
use mydia_p2p_core::{
    HlsRequest, HlsResponder, HlsResponseHeader, HLS_PEER_STOPPED, PEER_FILE_SESSION_PREFIX,
};
use std::collections::{HashMap, HashSet};
use std::future::Future;
use std::io::SeekFrom;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::Duration;
use tokio::io::{AsyncReadExt as _, AsyncSeekExt as _};
use tokio::sync::{mpsc, oneshot, Semaphore};

/// Concurrent reads one peer may have open. The next one waits for a slot.
pub(crate) const READS_PER_PEER: usize = 4;

/// How long a read waits for Dart to answer a grant request before it is
/// answered 502.
pub(crate) const GRANT_TIMEOUT: Duration = Duration::from_secs(10);

/// Read size for local files when the sink has no file streaming of its own.
const FILE_CHUNK: usize = 256 * 1024;

/// What Dart resolved a read path to: a local path or `file://` URL, or an
/// `http(s)` URL with the headers it needs (`WebDAV` credentials, say).
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct Grant {
    pub(crate) url: String,
    pub(crate) headers: Vec<(String, String)>,
}

/// What a grant request came back with.
#[derive(Clone, Debug, PartialEq)]
pub(crate) enum GrantAnswer {
    Granted(Grant),
    /// The path is not one the account shares: 404.
    NotShared,
    /// The path is shared but its backend could not be opened, or Dart did
    /// not answer in time: 502. Never cached.
    Failed,
}

/// Turns `(account id, path)` into a [`GrantAnswer`].
pub(crate) trait GrantResolver: Send + Sync + 'static {
    fn resolve(&self, account_id: &str, path: &str) -> impl Future<Output = GrantAnswer> + Send;
}

/// Where a read's response goes: an HLS response stream in the app, a
/// recorder in tests.
pub(crate) trait ByteSink: Send + Sync + 'static {
    fn header(&self, h: HlsResponseHeader) -> impl Future<Output = Result<(), String>> + Send;
    /// An `Err` means the viewer is gone, and nothing more should be read.
    fn chunk(&self, b: Vec<u8>) -> impl Future<Output = Result<(), String>> + Send;
    fn finish(&self) -> impl Future<Output = ()> + Send;
    fn abort(&self) -> impl Future<Output = ()> + Send;

    /// Send `length` bytes of the file at `path` from `offset`, after the
    /// header, and end the stream. An error starting with
    /// `HLS_PEER_STOPPED` means the viewer stopped reading; any other means
    /// the file could not be read.
    fn stream_file(
        &self,
        path: String,
        offset: u64,
        length: u64,
    ) -> impl Future<Output = Result<(), String>> + Send {
        async move { stream_file_in_chunks(self, &path, offset, length).await }
    }
}

/// The app's sink: one HLS response stream on the p2p host.
impl ByteSink for (HlsResponder, String) {
    async fn header(&self, h: HlsResponseHeader) -> Result<(), String> {
        self.0.send_header(self.1.clone(), h).await
    }

    async fn chunk(&self, b: Vec<u8>) -> Result<(), String> {
        self.0.send_chunk(self.1.clone(), b).await
    }

    async fn finish(&self) {
        if let Err(e) = self.0.finish(self.1.clone()).await {
            tracing::debug!("peer file stream {} did not finish: {e}", self.1);
        }
    }

    async fn abort(&self) {
        // The stream is often already gone (the viewer cancelled), which is
        // exactly what an abort would have achieved.
        let _ = self.0.abort(self.1.clone()).await;
    }

    /// The core reads the file and writes it to the QUIC stream itself,
    /// which skips a hop per chunk.
    async fn stream_file(&self, path: String, offset: u64, length: u64) -> Result<(), String> {
        self.0
            .stream_file_range(self.1.clone(), path, offset, length)
            .await
    }
}

async fn stream_file_in_chunks<S: ByteSink + ?Sized>(
    sink: &S,
    path: &str,
    offset: u64,
    length: u64,
) -> Result<(), String> {
    let mut file = match tokio::fs::File::open(path).await {
        Ok(file) => file,
        Err(e) => {
            sink.abort().await;
            return Err(format!("Failed to open {path}: {e}"));
        }
    };
    if let Err(e) = file.seek(SeekFrom::Start(offset)).await {
        sink.abort().await;
        return Err(format!("Failed to seek {path}: {e}"));
    }
    let mut remaining = length;
    while remaining > 0 {
        let want = usize::try_from(remaining).map_or(FILE_CHUNK, |r| r.min(FILE_CHUNK));
        let mut buf = vec![0u8; want];
        if let Err(e) = file.read_exact(&mut buf).await {
            sink.abort().await;
            return Err(format!("Failed to read {path}: {e}"));
        }
        remaining -= want as u64;
        if let Err(e) = sink.chunk(buf).await {
            return Err(format!("{HLS_PEER_STOPPED}: {e}"));
        }
    }
    sink.finish().await;
    Ok(())
}

/// How a read ended, which decides whether its grant is kept.
#[derive(Debug, PartialEq)]
enum Outcome {
    Done,
    /// The viewer went away. The grant is fine.
    Cancelled,
    /// The grant led nowhere readable, so it is dropped and the next read
    /// asks Dart again (an SMB share that moved, a file that was deleted).
    Failed,
}

/// Where a grant points.
enum Target {
    File(String),
    Http(String),
}

fn grant_target(url: &str) -> Option<Target> {
    match url::Url::parse(url) {
        Ok(parsed) => match parsed.scheme() {
            "http" | "https" => Some(Target::Http(url.to_string())),
            "file" => parsed
                .to_file_path()
                .ok()
                .and_then(|p| p.to_str().map(str::to_string))
                .map(Target::File),
            // A Windows path such as `C:\Movies\a.mkv` parses as scheme `c`.
            scheme if scheme.len() == 1 => Some(Target::File(url.to_string())),
            _ => None,
        },
        // No scheme: a plain path.
        Err(_) => Some(Target::File(url.to_string())),
    }
}

/// The byte span a request asks for out of `total`.
enum Span {
    Whole,
    /// Inclusive bounds.
    Part {
        start: u64,
        end: u64,
    },
    Unsatisfiable,
}

/// A range end past EOF is clamped to the last byte. A start at or past EOF
/// cannot be served at all.
fn span(range_start: Option<u64>, range_end: Option<u64>, total: u64) -> Span {
    if range_start.is_none() && range_end.is_none() {
        return Span::Whole;
    }
    let start = range_start.unwrap_or(0);
    if start >= total {
        return Span::Unsatisfiable;
    }
    let end = range_end.map_or(total - 1, |e| e.min(total - 1));
    if end < start {
        Span::Unsatisfiable
    } else {
        Span::Part { start, end }
    }
}

fn range_header(range_start: Option<u64>, range_end: Option<u64>) -> Option<String> {
    match (range_start, range_end) {
        (None, None) => None,
        (start, Some(end)) => Some(format!("bytes={}-{end}", start.unwrap_or(0))),
        (Some(start), None) => Some(format!("bytes={start}-")),
    }
}

/// The account id and decoded path a `peerfile:` request names, or `None`
/// when either is missing or the path is not base64url without padding.
fn read_target(request: &HlsRequest) -> Option<(String, String)> {
    let account_id = request.session_id.strip_prefix(PEER_FILE_SESSION_PREFIX)?;
    if account_id.is_empty() {
        return None;
    }
    let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(&request.path)
        .ok()?;
    let path = String::from_utf8(bytes).ok()?;
    if path.is_empty() {
        return None;
    }
    Some((account_id.to_string(), path))
}

/// The media type players expect for the files a library holds, by
/// extension.
fn content_type_for(path: &str) -> &'static str {
    let ext = std::path::Path::new(path)
        .extension()
        .and_then(|e| e.to_str())
        .map(str::to_ascii_lowercase);
    match ext.as_deref() {
        Some("mp4" | "m4v") => "video/mp4",
        Some("mkv") => "video/x-matroska",
        Some("webm") => "video/webm",
        Some("avi") => "video/x-msvideo",
        Some("mov") => "video/quicktime",
        Some("ts" | "m2ts" | "mts") => "video/mp2t",
        Some("mpg" | "mpeg") => "video/mpeg",
        Some("wmv") => "video/x-ms-wmv",
        Some("flv") => "video/x-flv",
        Some("srt") => "application/x-subrip",
        Some("vtt") => "text/vtt",
        Some("ass" | "ssa") => "text/x-ssa",
        Some("jpg" | "jpeg") => "image/jpeg",
        Some("png") => "image/png",
        Some("webp") => "image/webp",
        _ => "application/octet-stream",
    }
}

/// A header with no body, then the end of the stream.
async fn reply_status<S: ByteSink>(sink: &S, status: u16, content_range: Option<String>) {
    let header = HlsResponseHeader {
        status,
        content_type: "text/plain".to_string(),
        content_length: 0,
        content_range,
        cache_control: None,
    };
    if sink.header(header).await.is_ok() {
        sink.finish().await;
    }
}

type WantsVerifier = rustls::ConfigBuilder<rustls::ClientConfig, rustls::WantsVerifier>;
type WantsClientCert = rustls::ConfigBuilder<rustls::ClientConfig, rustls::client::WantsClientCert>;

/// The system's trust, as the lender's own Dart HTTP client has, so a share
/// whose certificate chains to a CA installed there plays for peers too.
/// Mozilla's roots when the system store cannot be read.
#[cfg(not(target_os = "android"))]
fn with_server_trust(builder: WantsVerifier) -> WantsClientCert {
    let provider = builder.crypto_provider().clone();
    match rustls_platform_verifier::Verifier::new(provider) {
        Ok(verifier) => builder
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(verifier)),
        Err(e) => {
            tracing::warn!("peer files: no system trust store, using Mozilla's roots: {e}");
            with_mozilla_roots(builder)
        }
    }
}

/// Mozilla's roots. The platform verifier needs a JNI handle on Android
/// that this app never gives it, so a share behind a CA only the device
/// trusts answers 502 to peers there.
#[cfg(target_os = "android")]
fn with_server_trust(builder: WantsVerifier) -> WantsClientCert {
    with_mozilla_roots(builder)
}

fn with_mozilla_roots(builder: WantsVerifier) -> WantsClientCert {
    builder.with_root_certificates(rustls::RootCertStore {
        roots: webpki_roots::TLS_SERVER_ROOTS.to_vec(),
    })
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

/// A client for `http(s)` grants with the ring provider iroh already uses.
/// `None` only if rustls rejects its own default protocol versions, in which
/// case `http(s)` grants answer 502.
fn http_client() -> Option<reqwest::Client> {
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let builder = rustls::ClientConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .inspect_err(|e| tracing::warn!("peer files: no TLS config: {e}"))
        .ok()?;
    let tls = with_server_trust(builder).with_no_client_auth();
    reqwest::Client::builder()
        .tls_backend_preconfigured(tls)
        .connect_timeout(Duration::from_secs(10))
        // A stalled upstream would otherwise hold one of the peer's slots
        // forever.
        .read_timeout(Duration::from_secs(30))
        // Never fetch a URL the grant did not name: a 3xx is answered 502.
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .inspect_err(|e| tracing::warn!("peer files: no HTTP client: {e}"))
        .ok()
}

pub(crate) struct PeerFilesHost<R> {
    resolver: R,
    /// Node ids of the active members of the sync group. Starts empty, so
    /// nothing is served until Dart says who may read.
    members: Mutex<HashSet<String>>,
    slots: Mutex<HashMap<String, Arc<Semaphore>>>,
    grants: Mutex<HashMap<(String, String), Grant>>,
    /// Bumped per account by `invalidate_account`. A resolve that started
    /// under an older generation is served but not cached, so an answer from
    /// before an invalidation never outlives it. Lock order: this, then
    /// `grants`.
    generations: Mutex<HashMap<String, u64>>,
    http: Option<reqwest::Client>,
}

impl<R: GrantResolver> PeerFilesHost<R> {
    pub(crate) fn new(resolver: R) -> Self {
        Self {
            resolver,
            members: Mutex::new(HashSet::new()),
            slots: Mutex::new(HashMap::new()),
            grants: Mutex::new(HashMap::new()),
            generations: Mutex::new(HashMap::new()),
            http: http_client(),
        }
    }

    pub(crate) fn resolver(&self) -> &R {
        &self.resolver
    }

    /// Replace the allowlist. Reads already streaming finish; a removed
    /// peer's next read is 403, and so is a read of its that was waiting for
    /// a slot or a grant.
    ///
    /// A removed peer's slots are dropped. If it is added back it gets a
    /// fresh set of [`READS_PER_PEER`], so reads it still had streaming from
    /// before do not count against them.
    ///
    /// Node ids are compared without regard to case, as Dart's roster does.
    pub(crate) fn set_members(&self, node_ids: Vec<String>) {
        let members: HashSet<String> = node_ids
            .into_iter()
            .map(|id| id.to_ascii_lowercase())
            .collect();
        lock(&self.slots).retain(|peer, _| members.contains(peer));
        *lock(&self.members) = members;
    }

    /// Drop every cached grant of `account_id`, for when its index changed.
    pub(crate) fn invalidate_account(&self, account_id: &str) {
        let mut generations = lock(&self.generations);
        *generations.entry(account_id.to_string()).or_insert(0) += 1;
        lock(&self.grants).retain(|(account, _), _| account != account_id);
    }

    fn generation(&self, account_id: &str) -> u64 {
        lock(&self.generations)
            .get(account_id)
            .copied()
            .unwrap_or(0)
    }

    fn is_member(&self, peer: &str) -> bool {
        lock(&self.members).contains(&peer.to_ascii_lowercase())
    }

    fn slots_for(&self, peer: &str) -> Arc<Semaphore> {
        lock(&self.slots)
            .entry(peer.to_ascii_lowercase())
            .or_insert_with(|| Arc::new(Semaphore::new(READS_PER_PEER)))
            .clone()
    }

    async fn grant(&self, account_id: &str, path: &str) -> GrantAnswer {
        let key = (account_id.to_string(), path.to_string());
        if let Some(grant) = lock(&self.grants).get(&key).cloned() {
            return GrantAnswer::Granted(grant);
        }
        let generation = self.generation(account_id);
        let answer = self.resolver.resolve(account_id, path).await;
        if let GrantAnswer::Granted(grant) = &answer {
            let generations = lock(&self.generations);
            if generations.get(account_id).copied().unwrap_or(0) == generation {
                lock(&self.grants).insert(key, grant.clone());
            }
        }
        answer
    }

    /// Answer one `peerfile:` read on `sink`.
    pub(crate) async fn serve<S: ByteSink>(&self, peer: String, request: HlsRequest, sink: S) {
        if !self.is_member(&peer) {
            tracing::info!("peer files: refusing a read from non-member {peer}");
            reply_status(&sink, 403, None).await;
            return;
        }
        let Some((account_id, path)) = read_target(&request) else {
            reply_status(&sink, 404, None).await;
            return;
        };
        // Taken before the grant so a peer cannot queue unbounded grant
        // requests into Dart either. Held until this function returns, which
        // is when the stream has ended.
        let Ok(_permit) = self.slots_for(&peer).acquire_owned().await else {
            // The semaphore is never closed, so this does not happen; end the
            // stream rather than leave the viewer waiting if it ever does.
            sink.abort().await;
            return;
        };
        // Membership can change while a read waits for a slot or a grant.
        if !self.is_member(&peer) {
            reply_status(&sink, 403, None).await;
            return;
        }
        let grant = match self.grant(&account_id, &path).await {
            GrantAnswer::Granted(grant) => grant,
            GrantAnswer::NotShared => {
                reply_status(&sink, 404, None).await;
                return;
            }
            GrantAnswer::Failed => {
                reply_status(&sink, 502, None).await;
                return;
            }
        };
        if !self.is_member(&peer) {
            reply_status(&sink, 403, None).await;
            return;
        }
        let outcome = match grant_target(&grant.url) {
            Some(Target::File(file)) => serve_file(&sink, &file, &request).await,
            Some(Target::Http(url)) => {
                self.serve_http(&sink, &url, &grant.headers, &path, &request)
                    .await
            }
            None => {
                tracing::warn!("peer files: grant for {account_id} has an unsupported scheme");
                reply_status(&sink, 404, None).await;
                Outcome::Failed
            }
        };
        if outcome == Outcome::Failed {
            lock(&self.grants).remove(&(account_id, path));
        }
    }

    async fn serve_http<S: ByteSink>(
        &self,
        sink: &S,
        url: &str,
        headers: &[(String, String)],
        read_path: &str,
        request: &HlsRequest,
    ) -> Outcome {
        let Some(client) = &self.http else {
            reply_status(sink, 502, None).await;
            return Outcome::Failed;
        };
        let mut upstream = client.get(url);
        for (name, value) in headers {
            upstream = upstream.header(name.as_str(), value.as_str());
        }
        if let Some(range) = range_header(request.range_start, request.range_end) {
            upstream = upstream.header(reqwest::header::RANGE, range);
        }
        // A 3xx is not followed (see `http_client`), so only a 2xx is served.
        let mut response = match upstream.send().await {
            Ok(response) if response.status().is_success() => response,
            Ok(response) => {
                tracing::warn!("peer files: upstream answered {}", response.status());
                reply_status(sink, 502, None).await;
                return Outcome::Failed;
            }
            Err(e) => {
                tracing::warn!("peer files: upstream unreachable: {e}");
                reply_status(sink, 502, None).await;
                return Outcome::Failed;
            }
        };
        // The response header has no way to say "length unknown": the viewer
        // sets Content-Length from it, and a body longer than that fails on
        // its side. An upstream that will not say how long the body is
        // cannot be relayed.
        let Some(content_length) = response.content_length() else {
            tracing::warn!("peer files: upstream sent no Content-Length");
            reply_status(sink, 502, None).await;
            return Outcome::Failed;
        };
        let text_header = |name: reqwest::header::HeaderName| {
            response
                .headers()
                .get(name)
                .and_then(|v| v.to_str().ok())
                .map(str::to_string)
        };
        let header = HlsResponseHeader {
            status: response.status().as_u16(),
            content_type: text_header(reqwest::header::CONTENT_TYPE)
                .unwrap_or_else(|| content_type_for(read_path).to_string()),
            content_length,
            content_range: text_header(reqwest::header::CONTENT_RANGE),
            cache_control: None,
        };
        if sink.header(header).await.is_err() {
            return Outcome::Cancelled;
        }
        loop {
            match response.chunk().await {
                Ok(Some(bytes)) => {
                    if sink.chunk(bytes.to_vec()).await.is_err() {
                        // Returning drops `response`, which closes the
                        // upstream connection: nothing more is read.
                        sink.abort().await;
                        return Outcome::Cancelled;
                    }
                }
                Ok(None) => {
                    sink.finish().await;
                    return Outcome::Done;
                }
                Err(e) => {
                    tracing::warn!("peer files: upstream body failed: {e}");
                    sink.abort().await;
                    return Outcome::Failed;
                }
            }
        }
    }
}

async fn serve_file<S: ByteSink>(sink: &S, path: &str, request: &HlsRequest) -> Outcome {
    let total = match tokio::fs::metadata(path).await {
        Ok(meta) if meta.is_file() => meta.len(),
        Ok(_) | Err(_) => {
            reply_status(sink, 404, None).await;
            return Outcome::Failed;
        }
    };
    let (status, offset, length, content_range) =
        match span(request.range_start, request.range_end, total) {
            Span::Whole => (200, 0, total, None),
            Span::Part { start, end } => (
                206,
                start,
                end - start + 1,
                Some(format!("bytes {start}-{end}/{total}")),
            ),
            Span::Unsatisfiable => {
                reply_status(sink, 416, Some(format!("bytes */{total}"))).await;
                return Outcome::Done;
            }
        };
    let header = HlsResponseHeader {
        status,
        content_type: content_type_for(path).to_string(),
        content_length: length,
        content_range,
        cache_control: None,
    };
    if sink.header(header).await.is_err() {
        return Outcome::Cancelled;
    }
    match sink.stream_file(path.to_string(), offset, length).await {
        Ok(()) => Outcome::Done,
        Err(e) if e.starts_with(HLS_PEER_STOPPED) => Outcome::Cancelled,
        Err(e) => {
            tracing::warn!("peer files: {e}");
            Outcome::Failed
        }
    }
}

/// Asks Dart for grants: each request goes out on a channel that
/// `peer_file_grant_stream` forwards to Dart, and Dart's answer comes back
/// through `respond`.
pub(crate) struct DartGrantResolver {
    requests: mpsc::Sender<FlutterPeerFileGrantRequest>,
    pending: Mutex<HashMap<String, oneshot::Sender<GrantAnswer>>>,
    next_id: AtomicU64,
    wait: Duration,
}

impl DartGrantResolver {
    /// The resolver and the receiving end of its requests. A request nobody
    /// answers within `wait` resolves to [`GrantAnswer::Failed`]: Dart not
    /// answering says nothing about whether the file is shared.
    pub(crate) fn new(wait: Duration) -> (Self, mpsc::Receiver<FlutterPeerFileGrantRequest>) {
        // Each peer holds at most READS_PER_PEER requests here at once, so
        // this only fills when Dart is not draining at all.
        let (tx, rx) = mpsc::channel(32);
        (
            Self {
                requests: tx,
                pending: Mutex::new(HashMap::new()),
                next_id: AtomicU64::new(0),
                wait,
            },
            rx,
        )
    }

    /// Deliver Dart's answer. An answer for a request that already timed out
    /// is dropped.
    pub(crate) fn respond(&self, request_id: &str, answer: GrantAnswer) {
        if let Some(tx) = lock(&self.pending).remove(request_id) {
            let _ = tx.send(answer);
        }
    }
}

impl GrantResolver for DartGrantResolver {
    // Trait methods are bound whatever the item's visibility.
    #[frb(ignore)]
    async fn resolve(&self, account_id: &str, path: &str) -> GrantAnswer {
        let request_id = self.next_id.fetch_add(1, Ordering::Relaxed).to_string();
        let (tx, rx) = oneshot::channel();
        lock(&self.pending).insert(request_id.clone(), tx);
        let sent = self.requests.try_send(FlutterPeerFileGrantRequest {
            request_id: request_id.clone(),
            account_id: account_id.to_string(),
            path: path.to_string(),
        });
        let answer = match sent {
            Ok(()) => timeout(self.wait, rx)
                .await
                .ok()
                .and_then(Result::ok)
                .unwrap_or(GrantAnswer::Failed),
            Err(e) => {
                tracing::warn!("peer files: cannot ask Dart for a grant: {e}");
                GrantAnswer::Failed
            }
        };
        lock(&self.pending).remove(&request_id);
        answer
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use bytes::Bytes;
    use http_body_util::{combinators::BoxBody, BodyExt, Full, StreamBody};
    use hyper::body::Frame;
    use hyper::{Request, Response};
    use hyper_util::rt::TokioIo;
    use mydia_p2p_core::runtime;
    use mydia_p2p_core::runtime::time::{sleep, Duration};
    use std::collections::HashMap;
    use std::convert::Infallible;
    use std::io::Write as _;
    use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
    use std::sync::{Arc, Mutex};
    use tokio::sync::Semaphore;

    const TOTAL: usize = 1024 * 1024;
    const MEMBER: &str = "member-node";
    const ACCOUNT: &str = "flocal";

    fn buffer() -> Vec<u8> {
        (0..=255u8).cycle().take(TOTAL).collect()
    }

    #[derive(Default)]
    struct Recorded {
        header: Option<HlsResponseHeader>,
        body: Vec<u8>,
        chunks: usize,
        finished: bool,
        aborted: bool,
    }

    /// Records what `serve` writes. `fail_after` makes `chunk` fail once that
    /// many chunks were taken, as a viewer that cancelled does. `gate` holds
    /// every `chunk` until the gate is closed, which then fails it.
    #[derive(Clone, Default)]
    struct RecordingSink {
        rec: Arc<Mutex<Recorded>>,
        fail_after: Option<usize>,
        gate: Option<Arc<Semaphore>>,
    }

    impl RecordingSink {
        fn gated() -> (Self, Arc<Semaphore>) {
            let gate = Arc::new(Semaphore::new(0));
            (
                Self {
                    gate: Some(gate.clone()),
                    ..Self::default()
                },
                gate,
            )
        }

        fn status(&self) -> Option<u16> {
            self.rec.lock().unwrap().header.as_ref().map(|h| h.status)
        }

        fn header(&self) -> HlsResponseHeader {
            self.rec.lock().unwrap().header.clone().expect("a header")
        }

        fn body(&self) -> Vec<u8> {
            self.rec.lock().unwrap().body.clone()
        }

        fn finished(&self) -> bool {
            self.rec.lock().unwrap().finished
        }
    }

    impl ByteSink for RecordingSink {
        async fn header(&self, h: HlsResponseHeader) -> Result<(), String> {
            self.rec.lock().unwrap().header = Some(h);
            Ok(())
        }

        async fn chunk(&self, b: Vec<u8>) -> Result<(), String> {
            if let Some(gate) = &self.gate {
                gate.acquire()
                    .await
                    .map_err(|_| "peer_stopped: gate closed".to_string())?
                    .forget();
            }
            let mut rec = self.rec.lock().unwrap();
            if self.fail_after.is_some_and(|n| rec.chunks >= n) {
                return Err("peer_stopped: viewer cancelled".to_string());
            }
            rec.chunks += 1;
            rec.body.extend_from_slice(&b);
            Ok(())
        }

        async fn finish(&self) {
            self.rec.lock().unwrap().finished = true;
        }

        async fn abort(&self) {
            self.rec.lock().unwrap().aborted = true;
        }
    }

    /// Answers from a fixed map and counts every call. A path in `failing`
    /// answers `Failed`, as a shared file whose backend is down does.
    #[derive(Default)]
    struct MapResolver {
        grants: Mutex<HashMap<(String, String), Grant>>,
        failing: Mutex<Vec<String>>,
        calls: AtomicUsize,
    }

    impl MapResolver {
        fn with(path: &str, url: &str) -> Self {
            let r = Self::default();
            r.grants.lock().unwrap().insert(
                (ACCOUNT.to_string(), path.to_string()),
                Grant {
                    url: url.to_string(),
                    headers: vec![("x-test-auth".to_string(), "secret".to_string())],
                },
            );
            r
        }

        fn calls(&self) -> usize {
            self.calls.load(Ordering::SeqCst)
        }
    }

    impl GrantResolver for MapResolver {
        async fn resolve(&self, account_id: &str, path: &str) -> GrantAnswer {
            self.calls.fetch_add(1, Ordering::SeqCst);
            if self.failing.lock().unwrap().iter().any(|p| p == path) {
                return GrantAnswer::Failed;
            }
            self.grants
                .lock()
                .unwrap()
                .get(&(account_id.to_string(), path.to_string()))
                .cloned()
                .map_or(GrantAnswer::NotShared, GrantAnswer::Granted)
        }
    }

    fn temp_file() -> tempfile::NamedTempFile {
        let mut f = tempfile::Builder::new().suffix(".mkv").tempfile().unwrap();
        f.write_all(&buffer()).unwrap();
        f.flush().unwrap();
        f
    }

    fn host_with<R: GrantResolver>(resolver: R) -> Arc<PeerFilesHost<R>> {
        let host = Arc::new(PeerFilesHost::new(resolver));
        host.set_members(vec![MEMBER.to_string()]);
        host
    }

    /// Answers one fixed grant, but only once the test lets each call
    /// through, so a test can act while a resolve is in flight.
    struct BlockingResolver {
        grant: Grant,
        entered: Semaphore,
        release: Semaphore,
        calls: AtomicUsize,
    }

    impl BlockingResolver {
        fn new(url: &str) -> Self {
            Self {
                grant: Grant {
                    url: url.to_string(),
                    headers: vec![],
                },
                entered: Semaphore::new(0),
                release: Semaphore::new(0),
                calls: AtomicUsize::new(0),
            }
        }
    }

    impl GrantResolver for BlockingResolver {
        async fn resolve(&self, _account_id: &str, _path: &str) -> GrantAnswer {
            self.calls.fetch_add(1, Ordering::SeqCst);
            self.entered.add_permits(1);
            self.release.acquire().await.unwrap().forget();
            GrantAnswer::Granted(self.grant.clone())
        }
    }

    fn request(path: &str, range_start: Option<u64>, range_end: Option<u64>) -> HlsRequest {
        HlsRequest {
            session_id: format!("{PEER_FILE_SESSION_PREFIX}{ACCOUNT}"),
            path: base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(path),
            range_start,
            range_end,
            auth_token: None,
        }
    }

    /// A loopback HTTP server over `buffer()` with Range support.
    /// `/fail` answers 500, `/redirect` a 302 to `/movie.mkv`, and
    /// `/nolength` a body without Content-Length. `/slow` sends 16 KiB frames 5 ms apart and counts
    /// the bytes it handed to the connection, so a test can tell whether the
    /// client kept reading.
    struct TestServer {
        base: String,
        slow_sent: Arc<AtomicU64>,
        seen_auth: Arc<Mutex<Vec<String>>>,
    }

    type TestBody = BoxBody<Bytes, Infallible>;

    fn parse_range(req: &Request<hyper::body::Incoming>) -> Option<(usize, usize)> {
        let value = req.headers().get(hyper::header::RANGE)?.to_str().ok()?;
        let spec = value.strip_prefix("bytes=")?;
        let (s, e) = spec.split_once('-')?;
        let start: usize = s.parse().ok()?;
        let end: usize = if e.is_empty() {
            TOTAL - 1
        } else {
            e.parse::<usize>().ok()?.min(TOTAL - 1)
        };
        Some((start, end))
    }

    #[expect(clippy::unused_async, reason = "hyper's service_fn wants a future")]
    async fn handle(
        req: Request<hyper::body::Incoming>,
        buf: Arc<Vec<u8>>,
        slow_sent: Arc<AtomicU64>,
        seen_auth: Arc<Mutex<Vec<String>>>,
    ) -> Result<Response<TestBody>, Infallible> {
        if let Some(auth) = req.headers().get("x-test-auth") {
            seen_auth
                .lock()
                .unwrap()
                .push(auth.to_str().unwrap().to_string());
        }
        if req.uri().path() == "/fail" {
            return Ok(Response::builder()
                .status(500)
                .body(Full::new(Bytes::new()).boxed())
                .unwrap());
        }
        if req.uri().path() == "/redirect" {
            return Ok(Response::builder()
                .status(302)
                .header("location", "/movie.mkv")
                .body(Full::new(Bytes::new()).boxed())
                .unwrap());
        }
        if req.uri().path() == "/nolength" {
            // A streamed body with no length: hyper sends it chunked.
            let piece = Bytes::copy_from_slice(&buf[..1000]);
            let stream = futures_util::stream::iter([Ok::<_, Infallible>(Frame::data(piece))]);
            return Ok(Response::builder()
                .status(200)
                .body(StreamBody::new(stream).boxed())
                .unwrap());
        }
        let (start, end, partial) = match parse_range(&req) {
            Some((s, e)) => (s, e, true),
            None => (0, TOTAL - 1, false),
        };
        let mut builder = Response::builder()
            .header("content-type", "video/x-matroska")
            .header("content-length", (end - start + 1).to_string());
        builder = if partial {
            builder
                .status(206)
                .header("content-range", format!("bytes {start}-{end}/{TOTAL}"))
        } else {
            builder.status(200)
        };
        if req.uri().path() == "/slow" {
            let (tx, rx) = mpsc::channel::<Bytes>(1);
            let data = buf[start..=end].to_vec();
            tokio::spawn(async move {
                for piece in data.chunks(16 * 1024) {
                    if tx.send(Bytes::copy_from_slice(piece)).await.is_err() {
                        break;
                    }
                    slow_sent.fetch_add(piece.len() as u64, Ordering::SeqCst);
                    sleep(Duration::from_millis(5)).await;
                }
            });
            let stream = futures_util::stream::unfold(rx, |mut rx| async move {
                rx.recv()
                    .await
                    .map(|b| (Ok::<_, Infallible>(Frame::data(b)), rx))
            });
            return Ok(builder.body(StreamBody::new(stream).boxed()).unwrap());
        }
        Ok(builder
            .body(Full::new(Bytes::copy_from_slice(&buf[start..=end])).boxed())
            .unwrap())
    }

    async fn start_server() -> TestServer {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let buf = Arc::new(buffer());
        let slow_sent = Arc::new(AtomicU64::new(0));
        let seen_auth = Arc::new(Mutex::new(Vec::new()));
        let (s, a) = (slow_sent.clone(), seen_auth.clone());
        tokio::spawn(async move {
            loop {
                let Ok((stream, _)) = listener.accept().await else {
                    return;
                };
                let (buf, s, a) = (buf.clone(), s.clone(), a.clone());
                tokio::spawn(async move {
                    let service = hyper::service::service_fn(move |req| {
                        handle(req, buf.clone(), s.clone(), a.clone())
                    });
                    let _ = hyper::server::conn::http1::Builder::new()
                        .serve_connection(TokioIo::new(stream), service)
                        .await;
                });
            }
        });
        TestServer {
            base: format!("http://{addr}"),
            slow_sent,
            seen_auth,
        }
    }

    async fn wait_for(sink: &RecordingSink, what: impl Fn(&RecordingSink) -> bool) {
        for _ in 0..200 {
            if what(sink) {
                return;
            }
            sleep(Duration::from_millis(10)).await;
        }
        panic!("condition never held");
    }

    #[test]
    fn non_member_gets_403() {
        runtime::block_on(async {
            let file = temp_file();
            let path = file.path().to_str().unwrap();
            let host = host_with(MapResolver::with(path, path));
            let sink = RecordingSink::default();
            host.serve(
                "stranger".to_string(),
                request(path, None, None),
                sink.clone(),
            )
            .await;
            assert_eq!(sink.status(), Some(403));
            assert!(sink.body().is_empty());
            assert!(sink.finished());
            assert_eq!(host.resolver().calls(), 0);
        });
    }

    #[test]
    fn allowlist_starts_empty() {
        runtime::block_on(async {
            let host = Arc::new(PeerFilesHost::new(MapResolver::default()));
            let sink = RecordingSink::default();
            host.serve(
                MEMBER.to_string(),
                request("/a.mkv", None, None),
                sink.clone(),
            )
            .await;
            assert_eq!(sink.status(), Some(403));
        });
    }

    #[test]
    fn unknown_grant_gets_404() {
        runtime::block_on(async {
            let host = host_with(MapResolver::default());
            let sink = RecordingSink::default();
            host.serve(
                MEMBER.to_string(),
                request("/nope.mkv", None, None),
                sink.clone(),
            )
            .await;
            assert_eq!(sink.status(), Some(404));
            assert!(sink.body().is_empty());
            assert!(sink.finished());
        });
    }

    #[test]
    fn bad_base64_path_gets_404() {
        runtime::block_on(async {
            let host = host_with(MapResolver::default());
            for bad in ["not base64!", "L2EubWt2==", "L2EubWt2+/"] {
                let sink = RecordingSink::default();
                let mut req = request("/a.mkv", None, None);
                req.path = bad.to_string();
                host.serve(MEMBER.to_string(), req, sink.clone()).await;
                assert_eq!(sink.status(), Some(404), "{bad}");
            }
            assert_eq!(host.resolver().calls(), 0);
        });
    }

    #[test]
    fn empty_account_id_gets_404() {
        runtime::block_on(async {
            let host = host_with(MapResolver::default());
            let sink = RecordingSink::default();
            let mut req = request("/a.mkv", None, None);
            req.session_id = PEER_FILE_SESSION_PREFIX.to_string();
            host.serve(MEMBER.to_string(), req, sink.clone()).await;
            assert_eq!(sink.status(), Some(404));
            assert_eq!(host.resolver().calls(), 0);
        });
    }

    #[test]
    fn file_range_returns_exact_bytes() {
        runtime::block_on(async {
            let file = temp_file();
            let path = file.path().to_str().unwrap();
            let host = host_with(MapResolver::with(path, path));
            let sink = RecordingSink::default();
            host.serve(
                MEMBER.to_string(),
                request(path, Some(100), Some(199)),
                sink.clone(),
            )
            .await;
            let header = sink.header();
            assert_eq!(header.status, 206);
            assert_eq!(
                header.content_range.as_deref(),
                Some("bytes 100-199/1048576")
            );
            assert_eq!(header.content_length, 100);
            assert_eq!(header.content_type, "video/x-matroska");
            assert_eq!(sink.body(), buffer()[100..200].to_vec());
            assert!(sink.finished());
        });
    }

    #[test]
    fn file_open_ended_range() {
        runtime::block_on(async {
            let file = temp_file();
            let path = file.path().to_str().unwrap();
            let host = host_with(MapResolver::with(path, path));
            let sink = RecordingSink::default();
            host.serve(
                MEMBER.to_string(),
                request(path, Some(1_048_000), None),
                sink.clone(),
            )
            .await;
            let header = sink.header();
            assert_eq!(header.status, 206);
            assert_eq!(
                header.content_range.as_deref(),
                Some("bytes 1048000-1048575/1048576")
            );
            assert_eq!(sink.body(), buffer()[1_048_000..].to_vec());
        });
    }

    #[test]
    fn file_without_range_is_200_and_whole() {
        runtime::block_on(async {
            let file = temp_file();
            let path = file.path().to_str().unwrap();
            let url = url::Url::from_file_path(path).unwrap().to_string();
            let host = host_with(MapResolver::with(path, &url));
            let sink = RecordingSink::default();
            host.serve(MEMBER.to_string(), request(path, None, None), sink.clone())
                .await;
            let header = sink.header();
            assert_eq!(header.status, 200);
            assert_eq!(header.content_range, None);
            assert_eq!(header.content_length, TOTAL as u64);
            assert_eq!(sink.body(), buffer());
        });
    }

    #[test]
    fn file_range_end_past_eof_is_clamped() {
        runtime::block_on(async {
            let file = temp_file();
            let path = file.path().to_str().unwrap();
            let host = host_with(MapResolver::with(path, path));
            let sink = RecordingSink::default();
            host.serve(
                MEMBER.to_string(),
                request(path, Some(1_048_570), Some(9_999_999)),
                sink.clone(),
            )
            .await;
            let header = sink.header();
            assert_eq!(
                header.content_range.as_deref(),
                Some("bytes 1048570-1048575/1048576")
            );
            assert_eq!(sink.body(), buffer()[1_048_570..].to_vec());
        });
    }

    #[test]
    fn file_range_start_past_eof_is_416() {
        runtime::block_on(async {
            let file = temp_file();
            let path = file.path().to_str().unwrap();
            let host = host_with(MapResolver::with(path, path));
            let sink = RecordingSink::default();
            host.serve(
                MEMBER.to_string(),
                request(path, Some(TOTAL as u64), None),
                sink.clone(),
            )
            .await;
            let header = sink.header();
            assert_eq!(header.status, 416);
            assert_eq!(header.content_range.as_deref(), Some("bytes */1048576"));
            assert!(sink.body().is_empty());
            assert!(sink.finished());
        });
    }

    #[test]
    fn http_range_forwards_status_and_bytes() {
        runtime::block_on(async {
            let server = start_server().await;
            let url = format!("{}/movie.mkv", server.base);
            let host = host_with(MapResolver::with("/share/movie.mkv", &url));
            let sink = RecordingSink::default();
            host.serve(
                MEMBER.to_string(),
                request("/share/movie.mkv", Some(1000), Some(4999)),
                sink.clone(),
            )
            .await;
            let header = sink.header();
            assert_eq!(header.status, 206);
            assert_eq!(
                header.content_range.as_deref(),
                Some("bytes 1000-4999/1048576")
            );
            assert_eq!(header.content_length, 4000);
            assert_eq!(header.content_type, "video/x-matroska");
            assert_eq!(sink.body(), buffer()[1000..5000].to_vec());
            assert!(sink.finished());
            assert_eq!(
                *server.seen_auth.lock().unwrap(),
                vec!["secret".to_string()]
            );
        });
    }

    #[test]
    fn http_without_range_forwards_200() {
        runtime::block_on(async {
            let server = start_server().await;
            let url = format!("{}/movie.mkv", server.base);
            let host = host_with(MapResolver::with("/share/movie.mkv", &url));
            let sink = RecordingSink::default();
            host.serve(
                MEMBER.to_string(),
                request("/share/movie.mkv", None, None),
                sink.clone(),
            )
            .await;
            let header = sink.header();
            assert_eq!(header.status, 200);
            assert_eq!(header.content_length, TOTAL as u64);
            assert_eq!(sink.body(), buffer());
        });
    }

    #[test]
    fn http_upstream_500_becomes_502() {
        runtime::block_on(async {
            let server = start_server().await;
            let url = format!("{}/fail", server.base);
            let host = host_with(MapResolver::with("/share/movie.mkv", &url));
            let sink = RecordingSink::default();
            host.serve(
                MEMBER.to_string(),
                request("/share/movie.mkv", None, None),
                sink.clone(),
            )
            .await;
            assert_eq!(sink.status(), Some(502));
            assert!(sink.body().is_empty());
            assert!(sink.finished());
        });
    }

    #[test]
    fn http_connection_error_becomes_502() {
        runtime::block_on(async {
            // Bind then drop, so nothing listens on the port.
            let port = std::net::TcpListener::bind("127.0.0.1:0")
                .unwrap()
                .local_addr()
                .unwrap()
                .port();
            let url = format!("http://127.0.0.1:{port}/movie.mkv");
            let host = host_with(MapResolver::with("/share/movie.mkv", &url));
            let sink = RecordingSink::default();
            host.serve(
                MEMBER.to_string(),
                request("/share/movie.mkv", None, None),
                sink.clone(),
            )
            .await;
            assert_eq!(sink.status(), Some(502));
        });
    }

    #[test]
    fn cancel_stops_upstream_reads() {
        runtime::block_on(async {
            let server = start_server().await;
            let url = format!("{}/slow", server.base);
            let host = host_with(MapResolver::with("/share/movie.mkv", &url));
            let sink = RecordingSink {
                fail_after: Some(1),
                ..RecordingSink::default()
            };
            host.serve(
                MEMBER.to_string(),
                request("/share/movie.mkv", None, None),
                sink.clone(),
            )
            .await;
            assert_eq!(sink.status(), Some(200));
            assert!(!sink.finished());
            // The whole body takes over 300 ms to send. Had the reader kept
            // going, the server would be well past 256 KiB by now.
            sleep(Duration::from_millis(500)).await;
            let sent = server.slow_sent.load(Ordering::SeqCst);
            assert!(
                sent < 256 * 1024,
                "server sent {sent} bytes after the cancel"
            );
        });
    }

    #[test]
    fn fifth_read_waits_for_a_slot() {
        runtime::block_on(async {
            let file = temp_file();
            let path = file.path().to_str().unwrap().to_string();
            let host = host_with(MapResolver::with(&path, &path));
            let _guard = runtime::enter();

            let mut gates = Vec::new();
            for _ in 0..4 {
                let (sink, gate) = RecordingSink::gated();
                let (h, p) = (host.clone(), path.clone());
                let s = sink.clone();
                runtime::spawn(async move {
                    h.serve(MEMBER.to_string(), request(&p, None, None), s)
                        .await;
                });
                wait_for(&sink, |s| s.status().is_some()).await;
                gates.push(gate);
            }

            let fifth = RecordingSink::default();
            let (h, p, s) = (host.clone(), path.clone(), fifth.clone());
            runtime::spawn(async move {
                h.serve(MEMBER.to_string(), request(&p, None, None), s)
                    .await;
            });
            sleep(Duration::from_millis(100)).await;
            assert_eq!(fifth.status(), None, "the fifth read must wait");

            // Another peer has slots of its own.
            host.set_members(vec![MEMBER.to_string(), "other-member".to_string()]);
            let other = RecordingSink::default();
            host.serve(
                "other-member".to_string(),
                request(&path, Some(0), Some(9)),
                other.clone(),
            )
            .await;
            assert_eq!(other.status(), Some(206));

            gates[0].close();
            wait_for(&fifth, |s| s.status().is_some()).await;
            wait_for(&fifth, RecordingSink::finished).await;
            assert_eq!(fifth.body(), buffer());
            for gate in &gates {
                gate.close();
            }
        });
    }

    #[test]
    fn grants_are_cached() {
        runtime::block_on(async {
            let file = temp_file();
            let path = file.path().to_str().unwrap();
            let host = host_with(MapResolver::with(path, path));
            for _ in 0..3 {
                let sink = RecordingSink::default();
                host.serve(
                    MEMBER.to_string(),
                    request(path, Some(0), Some(0)),
                    sink.clone(),
                )
                .await;
                assert_eq!(sink.status(), Some(206));
            }
            assert_eq!(host.resolver().calls(), 1);
        });
    }

    #[test]
    fn invalidate_drops_cached_grant() {
        runtime::block_on(async {
            let file = temp_file();
            let path = file.path().to_str().unwrap();
            let host = host_with(MapResolver::with(path, path));
            let serve = || async {
                let sink = RecordingSink::default();
                host.serve(
                    MEMBER.to_string(),
                    request(path, Some(0), Some(0)),
                    sink.clone(),
                )
                .await;
                assert_eq!(sink.status(), Some(206));
            };
            serve().await;
            host.invalidate_account("some-other-account");
            serve().await;
            assert_eq!(host.resolver().calls(), 1);
            host.invalidate_account(ACCOUNT);
            serve().await;
            assert_eq!(host.resolver().calls(), 2);
        });
    }

    #[test]
    fn failed_read_evicts_grant() {
        runtime::block_on(async {
            let server = start_server().await;
            let url = format!("{}/fail", server.base);
            let host = host_with(MapResolver::with("/share/movie.mkv", &url));
            for expected_calls in 1..=2 {
                let sink = RecordingSink::default();
                host.serve(
                    MEMBER.to_string(),
                    request("/share/movie.mkv", None, None),
                    sink.clone(),
                )
                .await;
                assert_eq!(sink.status(), Some(502));
                assert_eq!(host.resolver().calls(), expected_calls);
            }
        });
    }

    #[test]
    fn missing_local_file_is_404_and_evicts_grant() {
        runtime::block_on(async {
            let dir = tempfile::tempdir().unwrap();
            let gone = dir.path().join("gone.mkv");
            let gone = gone.to_str().unwrap();
            let host = host_with(MapResolver::with(gone, gone));
            for expected_calls in 1..=2 {
                let sink = RecordingSink::default();
                host.serve(MEMBER.to_string(), request(gone, None, None), sink.clone())
                    .await;
                assert_eq!(sink.status(), Some(404));
                assert_eq!(host.resolver().calls(), expected_calls);
            }
        });
    }

    #[test]
    fn removed_member_next_read_is_403() {
        runtime::block_on(async {
            let file = temp_file();
            let path = file.path().to_str().unwrap();
            let host = host_with(MapResolver::with(path, path));
            let sink = RecordingSink::default();
            host.serve(
                MEMBER.to_string(),
                request(path, Some(0), Some(9)),
                sink.clone(),
            )
            .await;
            assert_eq!(sink.status(), Some(206));

            host.set_members(vec![]);
            let sink = RecordingSink::default();
            host.serve(
                MEMBER.to_string(),
                request(path, Some(0), Some(9)),
                sink.clone(),
            )
            .await;
            assert_eq!(sink.status(), Some(403));
            assert!(sink.body().is_empty());
        });
    }

    #[test]
    fn read_queued_for_a_slot_is_403_once_its_peer_is_revoked() {
        runtime::block_on(async {
            let file = temp_file();
            let held = file.path().to_str().unwrap().to_string();
            let other = temp_file();
            let queued = other.path().to_str().unwrap().to_string();
            let resolver = MapResolver::with(&held, &held);
            resolver.grants.lock().unwrap().insert(
                (ACCOUNT.to_string(), queued.clone()),
                Grant {
                    url: queued.clone(),
                    headers: vec![],
                },
            );
            let host = host_with(resolver);
            let _guard = runtime::enter();

            let mut gates = Vec::new();
            for _ in 0..4 {
                let (sink, gate) = RecordingSink::gated();
                let (h, p, s) = (host.clone(), held.clone(), sink.clone());
                runtime::spawn(async move {
                    h.serve(MEMBER.to_string(), request(&p, None, None), s)
                        .await;
                });
                wait_for(&sink, |s| s.status().is_some()).await;
                gates.push(gate);
            }
            assert_eq!(host.resolver().calls(), 1);

            let fifth = RecordingSink::default();
            let (h, p, s) = (host.clone(), queued.clone(), fifth.clone());
            runtime::spawn(async move {
                h.serve(MEMBER.to_string(), request(&p, None, None), s)
                    .await;
            });
            sleep(Duration::from_millis(50)).await;
            assert_eq!(fifth.status(), None);

            host.set_members(vec![]);
            gates[0].close();
            wait_for(&fifth, |s| s.status().is_some()).await;
            assert_eq!(fifth.status(), Some(403));
            assert!(fifth.body().is_empty());
            // Only the held path was ever resolved: the queued read stopped
            // before asking for its grant.
            assert_eq!(host.resolver().calls(), 1);
            for gate in &gates {
                gate.close();
            }
        });
    }

    #[test]
    fn read_whose_peer_is_revoked_during_the_grant_is_403() {
        runtime::block_on(async {
            let file = temp_file();
            let path = file.path().to_str().unwrap().to_string();
            let host = host_with(BlockingResolver::new(&path));
            let _guard = runtime::enter();
            let sink = RecordingSink::default();
            let (h, p, s) = (host.clone(), path.clone(), sink.clone());
            let read = runtime::spawn(async move {
                h.serve(MEMBER.to_string(), request(&p, None, None), s)
                    .await;
            });
            host.resolver().entered.acquire().await.unwrap().forget();
            host.set_members(vec![]);
            host.resolver().release.add_permits(1);
            read.await.unwrap();
            assert_eq!(sink.status(), Some(403));
            assert!(sink.body().is_empty());
        });
    }

    #[test]
    fn grant_resolved_across_an_invalidation_is_served_but_not_cached() {
        runtime::block_on(async {
            let file = temp_file();
            let path = file.path().to_str().unwrap().to_string();
            let host = host_with(BlockingResolver::new(&path));
            let _guard = runtime::enter();
            let sink = RecordingSink::default();
            let (h, p, s) = (host.clone(), path.clone(), sink.clone());
            let read = runtime::spawn(async move {
                h.serve(MEMBER.to_string(), request(&p, Some(0), Some(9)), s)
                    .await;
            });
            host.resolver().entered.acquire().await.unwrap().forget();
            host.invalidate_account(ACCOUNT);
            host.resolver().release.add_permits(1);
            read.await.unwrap();
            assert_eq!(sink.status(), Some(206));
            assert_eq!(sink.body(), buffer()[..10].to_vec());

            // The next read asks again rather than using the stale answer.
            host.resolver().release.add_permits(1);
            let again = RecordingSink::default();
            host.serve(
                MEMBER.to_string(),
                request(&path, Some(0), Some(9)),
                again.clone(),
            )
            .await;
            assert_eq!(again.status(), Some(206));
            assert_eq!(host.resolver().calls.load(Ordering::SeqCst), 2);
        });
    }

    #[test]
    fn http_redirect_becomes_502_and_is_not_followed() {
        runtime::block_on(async {
            let server = start_server().await;
            let url = format!("{}/redirect", server.base);
            let host = host_with(MapResolver::with("/share/movie.mkv", &url));
            let sink = RecordingSink::default();
            host.serve(
                MEMBER.to_string(),
                request("/share/movie.mkv", None, None),
                sink.clone(),
            )
            .await;
            assert_eq!(sink.status(), Some(502));
            assert!(sink.body().is_empty());
            // One request reached the server: the redirect target never did.
            assert_eq!(server.seen_auth.lock().unwrap().len(), 1);
        });
    }

    #[test]
    fn http_without_content_length_becomes_502() {
        runtime::block_on(async {
            let server = start_server().await;
            let url = format!("{}/nolength", server.base);
            let host = host_with(MapResolver::with("/share/movie.mkv", &url));
            let sink = RecordingSink::default();
            host.serve(
                MEMBER.to_string(),
                request("/share/movie.mkv", None, None),
                sink.clone(),
            )
            .await;
            assert_eq!(sink.status(), Some(502));
            assert!(sink.body().is_empty());
        });
    }

    #[test]
    fn content_type_falls_back_to_octet_stream() {
        assert_eq!(content_type_for("/a/b.MP4"), "video/mp4");
        assert_eq!(content_type_for("/a/b.srt"), "application/x-subrip");
        assert_eq!(content_type_for("/a/b.weird"), "application/octet-stream");
        assert_eq!(content_type_for("/a/noext"), "application/octet-stream");
    }

    #[test]
    fn dart_resolver_round_trips_a_grant() {
        runtime::block_on(async {
            let (resolver, mut requests) = DartGrantResolver::new(Duration::from_secs(5));
            let resolver = Arc::new(resolver);
            let _guard = runtime::enter();
            let r = resolver.clone();
            let answer = runtime::spawn(async move { r.resolve("acct", "/x.mkv").await });
            let req = requests.recv().await.unwrap();
            assert_eq!(req.account_id, "acct");
            assert_eq!(req.path, "/x.mkv");
            let grant = Grant {
                url: "/x.mkv".to_string(),
                headers: vec![],
            };
            resolver.respond(&req.request_id, GrantAnswer::Granted(grant.clone()));
            assert_eq!(answer.await.unwrap(), GrantAnswer::Granted(grant));
        });
    }

    #[test]
    fn dart_resolver_passes_on_not_shared_and_failed() {
        runtime::block_on(async {
            let (resolver, mut requests) = DartGrantResolver::new(Duration::from_secs(5));
            let resolver = Arc::new(resolver);
            let _guard = runtime::enter();
            for expected in [GrantAnswer::NotShared, GrantAnswer::Failed] {
                let r = resolver.clone();
                let answer = runtime::spawn(async move { r.resolve("acct", "/x.mkv").await });
                let req = requests.recv().await.unwrap();
                resolver.respond(&req.request_id, expected.clone());
                assert_eq!(answer.await.unwrap(), expected);
            }
        });
    }

    #[test]
    fn dart_resolver_times_out_to_failed() {
        runtime::block_on(async {
            let (resolver, _requests) = DartGrantResolver::new(Duration::from_millis(50));
            assert_eq!(
                resolver.resolve("acct", "/x.mkv").await,
                GrantAnswer::Failed
            );
            assert!(resolver.pending.lock().unwrap().is_empty());
        });
    }

    #[test]
    fn grant_timeout_gets_502_not_404() {
        runtime::block_on(async {
            // Nobody drains the requests: Dart never answers.
            let (resolver, _requests) = DartGrantResolver::new(Duration::from_millis(50));
            let host = host_with(resolver);
            let sink = RecordingSink::default();
            host.serve(
                MEMBER.to_string(),
                request("/a.mkv", None, None),
                sink.clone(),
            )
            .await;
            assert_eq!(sink.status(), Some(502));
            assert!(sink.finished());
        });
    }

    #[test]
    fn failed_grant_gets_502_and_is_asked_again() {
        runtime::block_on(async {
            let resolver = MapResolver::default();
            resolver
                .failing
                .lock()
                .unwrap()
                .push("/down.mkv".to_string());
            let host = host_with(resolver);
            for _ in 0..2 {
                let sink = RecordingSink::default();
                host.serve(
                    MEMBER.to_string(),
                    request("/down.mkv", None, None),
                    sink.clone(),
                )
                .await;
                assert_eq!(sink.status(), Some(502));
                assert!(sink.body().is_empty());
            }
            // Never cached: each read asks Dart again.
            assert_eq!(host.resolver().calls(), 2);
        });
    }

    #[test]
    fn members_match_without_regard_to_case() {
        runtime::block_on(async {
            let file = temp_file();
            let path = file.path().to_str().unwrap();
            let host = Arc::new(PeerFilesHost::new(MapResolver::with(path, path)));
            host.set_members(vec!["ABCdef".to_string()]);
            for peer in ["abcdef", "ABCDEF", "ABCdef"] {
                let sink = RecordingSink::default();
                host.serve(
                    peer.to_string(),
                    request(path, Some(0), Some(0)),
                    sink.clone(),
                )
                .await;
                assert_eq!(sink.status(), Some(206), "{peer}");
            }
            let sink = RecordingSink::default();
            host.serve(
                "abcdeg".to_string(),
                request(path, Some(0), Some(0)),
                sink.clone(),
            )
            .await;
            assert_eq!(sink.status(), Some(403));
        });
    }
}
