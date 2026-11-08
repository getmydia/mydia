//! Pooled SMB2/3 client: listing, stat, probe, share enumeration and
//! positioned reads.
//!
//! One authenticated connection (session plus tree) is kept per
//! `(host, port, share, user, domain)` and reused. A sweep task, started on
//! first use, drops connections idle for the configured time. A connection
//! error evicts the pool entry, so the next call reconnects.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex as StdMutex, Weak};
use std::time::{Duration, Instant, UNIX_EPOCH};

use smb2::types::status::NtStatus;
use smb2::{ClientConfig, DirectoryEntry, FileInfo, FileReader, Tree};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::Mutex as AsyncMutex;

use crate::{SmbCredentials, SmbEntry, SmbError, SmbTarget};

/// Idle time after which a pooled connection is closed.
const DEFAULT_IDLE_TIMEOUT: Duration = Duration::from_mins(1);
/// Bound on TCP connect, so an unplugged NAS fails promptly.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
/// Bound on the raw SMB1 probe used to explain a failed negotiate.
const SMB1_PROBE_TIMEOUT: Duration = Duration::from_secs(3);

type PoolKey = (String, u16, String, String, Option<String>);

/// Which step a failing call was in. `STATUS_ACCESS_DENIED` means bad
/// credentials while signing in, and only a missing permission afterwards.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Phase {
    Connect,
    Operation,
}

/// An authenticated session on one share.
struct Session {
    client: smb2::SmbClient,
    tree: Tree,
}

/// A pool entry. Operations that need the session take its lock; reads on an
/// open file go through the file's own connection handle and do not.
struct Entry {
    session: AsyncMutex<Session>,
    last_used: StdMutex<Instant>,
    open_files: AtomicUsize,
}

impl Entry {
    fn touch(&self) {
        if let Ok(mut t) = self.last_used.lock() {
            *t = Instant::now();
        }
    }

    fn idle_for(&self) -> Duration {
        self.last_used
            .lock()
            .map_or(Duration::ZERO, |t| t.elapsed())
    }
}

/// The connection pool and the operations on it.
pub struct SmbClient {
    pool: StdMutex<HashMap<PoolKey, Arc<Entry>>>,
    idle_timeout: Duration,
    sweeper_started: AtomicBool,
    me: Weak<SmbClient>,
}

/// An open file, tied to the pooled connection it was opened on.
///
/// If that connection dies, `read_at` returns [`SmbError::Unreachable`] and
/// the caller opens the file again (which reconnects).
pub struct SmbFile {
    reader: FileReader,
    size: u64,
    entry: Arc<Entry>,
    owner: Weak<SmbClient>,
    key: PoolKey,
}

impl SmbClient {
    /// A client that closes connections idle for 60 s.
    pub fn new() -> Arc<Self> {
        Self::with_idle_timeout(DEFAULT_IDLE_TIMEOUT)
    }

    /// A client with a custom idle timeout.
    pub fn with_idle_timeout(idle_timeout: Duration) -> Arc<Self> {
        Arc::new_cyclic(|me| Self {
            pool: StdMutex::new(HashMap::new()),
            idle_timeout,
            sweeper_started: AtomicBool::new(false),
            me: me.clone(),
        })
    }

    /// Number of pooled connections.
    #[cfg(feature = "test-introspection")]
    pub fn pool_size(&self) -> usize {
        self.pool.lock().map_or(0, |p| p.len())
    }

    /// Whether a pooled connection exists for a target and login.
    #[cfg(feature = "test-introspection")]
    pub fn has_connection(&self, t: &SmbTarget, c: &SmbCredentials) -> bool {
        self.lookup(&pool_key(t, c)).is_some()
    }

    /// Drop the pooled connection for a target and login, if any. Files
    /// already open on it keep it alive until they are dropped; the next
    /// call for that pair connects afresh.
    pub fn close(&self, t: &SmbTarget, c: &SmbCredentials) {
        let removed = self
            .pool
            .lock()
            .ok()
            .and_then(|mut pool| pool.remove(&pool_key(t, c)));
        // Dropped outside the pool lock.
        drop(removed);
    }

    /// List a directory. `.` and `..` are skipped. Directories the account
    /// cannot open come back with `unreadable` set instead of failing the
    /// listing. Only directories are probed, with one stat each.
    pub async fn list(
        &self,
        t: &SmbTarget,
        c: &SmbCredentials,
        dir: &str,
    ) -> Result<Vec<SmbEntry>, SmbError> {
        let (key, entry) = self.checkout(t, c).await?;
        let result = {
            let mut guard = entry.session.lock().await;
            let session = &mut *guard;
            let rel = relative(dir);
            match session.client.list_directory(&mut session.tree, &rel).await {
                Ok(raw) => {
                    let mut entries: Vec<SmbEntry> = raw
                        .iter()
                        .filter(|e| e.name != "." && e.name != "..")
                        .map(|e| to_entry(dir, e))
                        .collect();
                    mark_unreadable(session, &mut entries).await;
                    Ok(entries)
                }
                Err(e) => Err(e),
            }
        };
        self.finish(&key, &entry, result, Phase::Operation)
    }

    /// Stat a path. A path that does not exist is `Ok(None)`.
    pub async fn stat(
        &self,
        t: &SmbTarget,
        c: &SmbCredentials,
        path: &str,
    ) -> Result<Option<SmbEntry>, SmbError> {
        let (key, entry) = self.checkout(t, c).await?;
        let result = {
            let mut guard = entry.session.lock().await;
            let session = &mut *guard;
            session
                .client
                .stat(&mut session.tree, &relative(path))
                .await
                .map(|info| to_entry_from_info(path, &info))
        };
        match self.finish(&key, &entry, result, Phase::Operation) {
            Err(SmbError::NotFound) => Ok(None),
            other => other.map(Some),
        }
    }

    /// Check that the share can be reached and `root` is a readable
    /// directory.
    pub async fn probe(
        &self,
        t: &SmbTarget,
        c: &SmbCredentials,
        root: &str,
    ) -> Result<(), SmbError> {
        let (key, entry) = self.checkout(t, c).await?;
        let result = {
            let mut guard = entry.session.lock().await;
            let session = &mut *guard;
            session
                .client
                .list_directory(&mut session.tree, &relative(root))
                .await
                .map(|_| ())
        };
        self.finish(&key, &entry, result, Phase::Operation)
    }

    /// Disk shares offered by a server. Admin shares (`IPC$`, `C$`, any name
    /// ending in `$`) are left out. Uses a throwaway connection.
    pub async fn list_shares(
        &self,
        host: &str,
        port: u16,
        c: &SmbCredentials,
    ) -> Result<Vec<String>, SmbError> {
        let mut client = connect(host, port, c).await?;
        let shares = client
            .list_shares()
            .await
            .map_err(|e| map_list_shares_error(&e))?;
        Ok(shares
            .into_iter()
            .map(|s| s.name)
            .filter(|n| !n.ends_with('$'))
            .collect())
    }

    /// Open a file for positioned reads on its pooled connection.
    pub async fn open(
        &self,
        t: &SmbTarget,
        c: &SmbCredentials,
        path: &str,
    ) -> Result<SmbFile, SmbError> {
        let (key, entry) = self.checkout(t, c).await?;
        let result = {
            let mut guard = entry.session.lock().await;
            let session = &mut *guard;
            session
                .client
                .open_file_reader(&session.tree, &relative(path))
                .await
        };
        let reader = self.finish(&key, &entry, result, Phase::Operation)?;
        entry.open_files.fetch_add(1, Ordering::AcqRel);
        Ok(SmbFile {
            size: reader.size(),
            reader,
            entry,
            owner: self.me.clone(),
            key,
        })
    }

    /// Get the pooled entry for a target, connecting if there is none.
    async fn checkout(
        &self,
        t: &SmbTarget,
        c: &SmbCredentials,
    ) -> Result<(PoolKey, Arc<Entry>), SmbError> {
        self.ensure_sweeper();
        let key = pool_key(t, c);
        if let Some(entry) = self.lookup(&key) {
            entry.touch();
            return Ok((key, entry));
        }
        let mut client = connect(&t.host, t.port, c).await?;
        let tree = client
            .connect_share(&t.share)
            .await
            .map_err(|e| map_error(&e, Phase::Connect))?;
        let fresh = Arc::new(Entry {
            session: AsyncMutex::new(Session { client, tree }),
            last_used: StdMutex::new(Instant::now()),
            open_files: AtomicUsize::new(0),
        });
        let mut pool = self
            .pool
            .lock()
            .map_err(|_| SmbError::Other("pool poisoned".to_string()))?;
        // Two callers may have raced to connect: keep the first.
        let entry = pool.entry(key.clone()).or_insert(fresh).clone();
        drop(pool);
        entry.touch();
        Ok((key, entry))
    }

    fn lookup(&self, key: &PoolKey) -> Option<Arc<Entry>> {
        self.pool.lock().ok()?.get(key).cloned()
    }

    /// Remove `entry` from the pool if it is still the one stored under `key`.
    fn evict(&self, key: &PoolKey, entry: &Arc<Entry>) {
        if let Ok(mut pool) = self.pool.lock() {
            if pool.get(key).is_some_and(|e| Arc::ptr_eq(e, entry)) {
                pool.remove(key);
            }
        }
    }

    /// Drop connections idle past the timeout. A connection with open files
    /// stays: its reads keep it fresh, and a paused player should not lose it.
    fn sweep(&self) {
        if let Ok(mut pool) = self.pool.lock() {
            let timeout = self.idle_timeout;
            pool.retain(|_, e| e.open_files.load(Ordering::Acquire) > 0 || e.idle_for() < timeout);
        }
    }

    /// Map an smb2 result, evicting the entry when the connection is gone.
    fn finish<T>(
        &self,
        key: &PoolKey,
        entry: &Arc<Entry>,
        result: Result<T, smb2::Error>,
        phase: Phase,
    ) -> Result<T, SmbError> {
        match result {
            Ok(v) => {
                entry.touch();
                Ok(v)
            }
            Err(e) => {
                let mapped = map_error(&e, phase);
                if matches!(mapped, SmbError::Unreachable(_)) {
                    self.evict(key, entry);
                }
                Err(mapped)
            }
        }
    }

    /// Start the idle sweep on first use. It holds the client weakly, so it
    /// ends when the client is dropped.
    fn ensure_sweeper(&self) {
        if self.sweeper_started.swap(true, Ordering::AcqRel) {
            return;
        }
        let me = self.me.clone();
        let period = (self.idle_timeout / 4).max(Duration::from_millis(50));
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(period).await;
                let Some(client) = me.upgrade() else { break };
                client.sweep();
            }
        });
    }
}

impl SmbFile {
    /// File size when it was opened.
    pub fn size(&self) -> u64 {
        self.size
    }

    /// Read up to `len` bytes at `offset`. Shorter only at end of file.
    pub async fn read_at(&self, offset: u64, len: usize) -> Result<Vec<u8>, SmbError> {
        self.entry.touch();
        match self.reader.read_at(offset, len as u64).await {
            Ok(data) => Ok(data),
            Err(e) => {
                let mapped = map_error(&e, Phase::Operation);
                if matches!(mapped, SmbError::Unreachable(_)) {
                    if let Some(owner) = self.owner.upgrade() {
                        owner.evict(&self.key, &self.entry);
                    }
                }
                Err(mapped)
            }
        }
    }
}

impl Drop for SmbFile {
    fn drop(&mut self) {
        self.entry.open_files.fetch_sub(1, Ordering::AcqRel);
    }
}

fn pool_key(t: &SmbTarget, c: &SmbCredentials) -> PoolKey {
    (
        t.host.clone(),
        t.port,
        t.share.clone(),
        c.user.clone(),
        c.domain.clone(),
    )
}

/// `/a/b` to `a/b` (smb2 paths are share-relative with no leading slash).
fn relative(path: &str) -> String {
    path.trim_matches('/').to_string()
}

/// Child path under a directory, both in `/`-separated absolute form.
fn join(dir: &str, name: &str) -> String {
    let dir = dir.trim_end_matches('/');
    format!("{dir}/{name}")
}

fn filetime_ms(t: smb2::pack::FileTime) -> i64 {
    match t.to_system_time() {
        Some(st) => match st.duration_since(UNIX_EPOCH) {
            Ok(d) => i64::try_from(d.as_millis()).unwrap_or(i64::MAX),
            Err(e) => -i64::try_from(e.duration().as_millis()).unwrap_or(i64::MAX),
        },
        None => 0,
    }
}

fn to_entry(dir: &str, e: &DirectoryEntry) -> SmbEntry {
    SmbEntry {
        path: join(dir, &e.name),
        name: e.name.clone(),
        is_dir: e.is_directory,
        size: e.size,
        modified_ms: filetime_ms(e.modified),
        unreadable: false,
    }
}

fn to_entry_from_info(path: &str, info: &FileInfo) -> SmbEntry {
    let trimmed = path.trim_end_matches('/');
    let name = trimmed.rsplit('/').next().unwrap_or_default().to_string();
    SmbEntry {
        path: if trimmed.is_empty() {
            "/".to_string()
        } else {
            trimmed.to_string()
        },
        name,
        is_dir: info.is_directory,
        size: info.size,
        modified_ms: filetime_ms(info.modified),
        unreadable: false,
    }
}

/// Stat every directory entry in one batch and flag the ones the server
/// refuses with `STATUS_ACCESS_DENIED`. Any other outcome leaves the entry
/// readable: this is a hint for the UI, and must never fail the listing.
async fn mark_unreadable(session: &mut Session, entries: &mut [SmbEntry]) {
    let dirs: Vec<usize> = entries
        .iter()
        .enumerate()
        .filter(|(_, e)| e.is_dir)
        .map(|(i, _)| i)
        .collect();
    if dirs.is_empty() {
        return;
    }
    let paths: Vec<String> = dirs.iter().map(|&i| relative(&entries[i].path)).collect();
    let refs: Vec<&str> = paths.iter().map(String::as_str).collect();
    let results = session.client.stat_files(&session.tree, &refs).await;
    for (&i, result) in dirs.iter().zip(results) {
        if let Err(e) = result {
            if e.status() == Some(NtStatus::ACCESS_DENIED) {
                entries[i].unreadable = true;
            }
        }
    }
}

/// Dial, negotiate and authenticate. A failed negotiate is checked against a
/// raw SMB1 probe so an SMB1-only NAS gets its own error.
async fn connect(host: &str, port: u16, c: &SmbCredentials) -> Result<smb2::SmbClient, SmbError> {
    let addr = if host.contains(':') && !host.starts_with('[') {
        format!("[{host}]:{port}")
    } else {
        format!("{host}:{port}")
    };
    let config = ClientConfig {
        addr,
        timeout: CONNECT_TIMEOUT,
        username: c.user.clone(),
        password: c.password.clone(),
        domain: c.domain.clone().unwrap_or_default(),
        auto_reconnect: false,
        ..Default::default()
    };
    match smb2::SmbClient::connect(config).await {
        Ok(client) => Ok(client),
        Err(e) => {
            if negotiate_may_have_hit_smb1(&e) && server_speaks_only_smb1(host, port).await {
                return Err(SmbError::Smb1Only);
            }
            Err(map_error(&e, Phase::Connect))
        }
    }
}

/// An SMB1-only server drops the connection (or sends something smb2 cannot
/// parse) in answer to an SMB2 NEGOTIATE. Those are the errors worth a probe.
/// A refused connect, a timeout or a rejected login are not.
fn negotiate_may_have_hit_smb1(e: &smb2::Error) -> bool {
    matches!(
        e,
        smb2::Error::Disconnected | smb2::Error::Io(_) | smb2::Error::InvalidData { .. }
    )
}

/// smb2 does not report why a negotiate failed, so ask the server directly:
/// send an SMB1 `NEGOTIATE` for `NT LM 0.12`. A server that also speaks SMB2
/// answers with an SMB2 header (`0xFE 'S' 'M' 'B'`), an SMB1-only one with an
/// SMB1 header (`0xFF 'S' 'M' 'B'`). Anything else, or no answer, is not
/// taken as proof.
async fn server_speaks_only_smb1(host: &str, port: u16) -> bool {
    let probe = async {
        let mut stream = tokio::net::TcpStream::connect((host, port)).await.ok()?;
        let mut packet = vec![0x00, 0x00, 0x00, 47];
        packet.extend_from_slice(&[0xFF, b'S', b'M', b'B', 0x72]);
        packet.extend_from_slice(&[0; 4]); // status
        packet.push(0x18); // flags
        packet.extend_from_slice(&[0x53, 0xC8]); // flags2
        packet.extend_from_slice(&[0; 2]); // pid high
        packet.extend_from_slice(&[0; 8]); // signature
        packet.extend_from_slice(&[0; 2]); // reserved
        packet.extend_from_slice(&[0xFF, 0xFF, 0xFE, 0xFF, 0, 0, 0, 0]); // tid, pid, uid, mid
        packet.push(0); // word count
        packet.extend_from_slice(&[12, 0]); // byte count
        packet.push(0x02);
        packet.extend_from_slice(b"NT LM 0.12\0");
        stream.write_all(&packet).await.ok()?;
        let mut reply = [0_u8; 8];
        stream.read_exact(&mut reply).await.ok()?;
        Some(reply[4..8] == [0xFF, b'S', b'M', b'B'])
    };
    tokio::time::timeout(SMB1_PROBE_TIMEOUT, probe)
        .await
        .ok()
        .flatten()
        .unwrap_or(false)
}

/// Translate an smb2 error following the spec's table.
fn map_error(e: &smb2::Error, phase: Phase) -> SmbError {
    use smb2::ErrorKind as K;
    if let smb2::Error::Protocol { status, .. } = e {
        if let Some(mapped) = map_status(*status, phase) {
            return mapped;
        }
    }
    match e.kind() {
        K::AuthRequired | K::GuestSessionRefused => SmbError::Unauthorized,
        K::NotFound => SmbError::NotFound,
        K::ConnectionLost | K::TimedOut | K::Io | K::SessionExpired => {
            SmbError::Unreachable(e.to_string())
        }
        _ => SmbError::Other(e.to_string()),
    }
}

/// Share enumeration tree-connects `IPC$` before its RPC call, so a refusal
/// there is a rejected login, not a missing permission on some object.
fn map_list_shares_error(e: &smb2::Error) -> SmbError {
    map_error(e, Phase::Connect)
}

/// Status codes with a fixed meaning. `None` falls through to the generic
/// classification.
fn map_status(status: NtStatus, phase: Phase) -> Option<SmbError> {
    match status {
        NtStatus::LOGON_FAILURE => Some(SmbError::Unauthorized),
        NtStatus::ACCESS_DENIED => Some(match phase {
            Phase::Connect => SmbError::Unauthorized,
            Phase::Operation => SmbError::AccessDenied,
        }),
        NtStatus::OBJECT_NAME_NOT_FOUND
        | NtStatus::OBJECT_PATH_NOT_FOUND
        | NtStatus::NO_SUCH_FILE
        | NtStatus::BAD_NETWORK_NAME => Some(SmbError::NotFound),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn logon_failure_is_unauthorized() {
        assert!(matches!(
            map_status(NtStatus::LOGON_FAILURE, Phase::Connect),
            Some(SmbError::Unauthorized)
        ));
    }

    #[test]
    fn access_denied_depends_on_phase() {
        assert!(matches!(
            map_status(NtStatus::ACCESS_DENIED, Phase::Connect),
            Some(SmbError::Unauthorized)
        ));
        assert!(matches!(
            map_status(NtStatus::ACCESS_DENIED, Phase::Operation),
            Some(SmbError::AccessDenied)
        ));
    }

    #[test]
    fn denied_share_enumeration_is_unauthorized() {
        let e = smb2::Error::Protocol {
            status: NtStatus::ACCESS_DENIED,
            command: smb2::types::Command::TreeConnect,
        };
        assert!(matches!(map_list_shares_error(&e), SmbError::Unauthorized));
    }

    #[test]
    fn missing_names_are_not_found() {
        for s in [
            NtStatus::OBJECT_NAME_NOT_FOUND,
            NtStatus::OBJECT_PATH_NOT_FOUND,
            NtStatus::BAD_NETWORK_NAME,
        ] {
            assert!(matches!(
                map_status(s, Phase::Operation),
                Some(SmbError::NotFound)
            ));
        }
    }

    #[test]
    fn transport_errors_are_unreachable() {
        for e in [smb2::Error::Disconnected, smb2::Error::Timeout] {
            assert!(matches!(
                map_error(&e, Phase::Operation),
                SmbError::Unreachable(_)
            ));
        }
    }

    #[test]
    fn relative_and_join() {
        assert_eq!(relative("/"), "");
        assert_eq!(relative("/a/b/"), "a/b");
        assert_eq!(join("/", "x"), "/x");
        assert_eq!(join("/a", "x"), "/a/x");
    }
}
