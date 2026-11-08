//! SMB2/3 access for the files library, exposed to Dart. The protocol lives
//! in `mydia_smb`; this module maps its types onto FFI-friendly ones and keeps
//! one client and one loopback range server for the whole app.
//!
//! The structs and enums are defined on every target because `flutter_rust_bridge`
//! generates bindings for all of them. In a browser there is no socket to open,
//! so every function answers [`FfiSmbErrorKind::Unsupported`].

pub struct FfiSmbTarget {
    pub host: String,
    pub port: u16,
    pub share: String,
}

pub struct FfiSmbCredentials {
    pub user: String,
    pub password: String,
    pub domain: Option<String>,
}

/// Sizes and times are `i64`: a `u64` would reach Dart as a `BigInt`.
pub struct FfiSmbEntry {
    pub path: String,
    pub name: String,
    pub is_dir: bool,
    pub size: i64,
    pub modified_ms: i64,
    pub unreadable: bool,
}

pub enum FfiSmbErrorKind {
    Unreachable,
    Unauthorized,
    /// Signed in, but the account lacks permission for the object.
    AccessDenied,
    NotFound,
    Smb1Only,
    Unsupported,
    Other,
}

pub struct FfiSmbError {
    pub kind: FfiSmbErrorKind,
    pub message: String,
}

pub enum FfiHeal {
    Healthy,
    ReboundSamePort,
    ReboundNewPort,
}

pub async fn smb_list(
    target: FfiSmbTarget,
    creds: FfiSmbCredentials,
    dir: String,
) -> Result<Vec<FfiSmbEntry>, FfiSmbError> {
    imp::list(target, creds, dir).await
}

/// `None` when the path does not exist.
pub async fn smb_stat(
    target: FfiSmbTarget,
    creds: FfiSmbCredentials,
    path: String,
) -> Result<Option<FfiSmbEntry>, FfiSmbError> {
    imp::stat(target, creds, path).await
}

/// Succeeds when the share is reachable and `root` is a readable directory.
pub async fn smb_probe(
    target: FfiSmbTarget,
    creds: FfiSmbCredentials,
    root: String,
) -> Result<(), FfiSmbError> {
    imp::probe(target, creds, root).await
}

pub async fn smb_list_shares(
    host: String,
    port: u16,
    creds: FfiSmbCredentials,
) -> Result<Vec<String>, FfiSmbError> {
    imp::list_shares(host, port, creds).await
}

/// Starts the loopback server on first use and returns the URL for `path`.
pub async fn smb_open(
    account_id: String,
    target: FfiSmbTarget,
    creds: FfiSmbCredentials,
    path: String,
) -> Result<String, FfiSmbError> {
    imp::open(account_id, target, creds, path).await
}

/// Forgets the account's playback URLs and closes their connections.
pub async fn smb_close_account(account_id: String) -> Result<(), FfiSmbError> {
    imp::close_account(account_id).await
}

/// `Healthy` while no server has been started.
pub async fn smb_heal_listener() -> Result<FfiHeal, FfiSmbError> {
    imp::heal_listener().await
}

#[cfg(not(target_arch = "wasm32"))]
pub(crate) mod imp {
    use super::{
        FfiHeal, FfiSmbCredentials, FfiSmbEntry, FfiSmbError, FfiSmbErrorKind, FfiSmbTarget,
    };
    use mydia_p2p_core::runtime;
    use mydia_smb::{Heal, SmbClient, SmbCredentials, SmbEntry, SmbError, SmbTarget, StreamServer};
    use std::future::Future;
    use std::sync::{Arc, OnceLock};
    use tokio::sync::OnceCell;

    static CLIENT: OnceLock<Arc<SmbClient>> = OnceLock::new();
    static SERVER: OnceCell<Arc<StreamServer>> = OnceCell::const_new();

    fn client() -> Arc<SmbClient> {
        CLIENT.get_or_init(SmbClient::new).clone()
    }

    fn other(message: String) -> FfiSmbError {
        FfiSmbError {
            kind: FfiSmbErrorKind::Other,
            message,
        }
    }

    impl From<SmbError> for FfiSmbError {
        fn from(e: SmbError) -> Self {
            let message = e.to_string();
            let kind = match e {
                SmbError::Unreachable(_) => FfiSmbErrorKind::Unreachable,
                SmbError::Unauthorized => FfiSmbErrorKind::Unauthorized,
                SmbError::AccessDenied => FfiSmbErrorKind::AccessDenied,
                SmbError::NotFound => FfiSmbErrorKind::NotFound,
                SmbError::Smb1Only => FfiSmbErrorKind::Smb1Only,
                SmbError::Other(_) => FfiSmbErrorKind::Other,
            };
            Self { kind, message }
        }
    }

    impl From<FfiSmbTarget> for SmbTarget {
        fn from(t: FfiSmbTarget) -> Self {
            Self {
                host: t.host,
                port: t.port,
                share: t.share,
            }
        }
    }

    impl From<FfiSmbCredentials> for SmbCredentials {
        fn from(c: FfiSmbCredentials) -> Self {
            Self {
                user: c.user,
                password: c.password,
                domain: c.domain,
            }
        }
    }

    impl From<SmbEntry> for FfiSmbEntry {
        fn from(e: SmbEntry) -> Self {
            Self {
                path: e.path,
                name: e.name,
                is_dir: e.is_dir,
                // Clamped: a size past i64::MAX is not a real file.
                size: i64::try_from(e.size).unwrap_or(i64::MAX),
                modified_ms: e.modified_ms,
                unreadable: e.unreadable,
            }
        }
    }

    /// Runs `fut` on the core runtime. This is called from the Dart isolate
    /// thread, which has no reactor of its own.
    async fn run<T, F>(fut: F) -> Result<T, FfiSmbError>
    where
        T: Send + 'static,
        F: Future<Output = Result<T, FfiSmbError>> + Send + 'static,
    {
        let handle = {
            let _guard = runtime::enter();
            runtime::spawn(fut)
        };
        handle
            .await
            .map_err(|e| other(format!("task failed: {e}")))?
    }

    pub(crate) async fn list(
        target: FfiSmbTarget,
        creds: FfiSmbCredentials,
        dir: String,
    ) -> Result<Vec<FfiSmbEntry>, FfiSmbError> {
        run(async move {
            let (t, c) = (SmbTarget::from(target), SmbCredentials::from(creds));
            let entries = client().list(&t, &c, &dir).await?;
            Ok(entries.into_iter().map(FfiSmbEntry::from).collect())
        })
        .await
    }

    pub(crate) async fn stat(
        target: FfiSmbTarget,
        creds: FfiSmbCredentials,
        path: String,
    ) -> Result<Option<FfiSmbEntry>, FfiSmbError> {
        run(async move {
            let (t, c) = (SmbTarget::from(target), SmbCredentials::from(creds));
            Ok(client().stat(&t, &c, &path).await?.map(FfiSmbEntry::from))
        })
        .await
    }

    pub(crate) async fn probe(
        target: FfiSmbTarget,
        creds: FfiSmbCredentials,
        root: String,
    ) -> Result<(), FfiSmbError> {
        run(async move {
            let (t, c) = (SmbTarget::from(target), SmbCredentials::from(creds));
            Ok(client().probe(&t, &c, &root).await?)
        })
        .await
    }

    pub(crate) async fn list_shares(
        host: String,
        port: u16,
        creds: FfiSmbCredentials,
    ) -> Result<Vec<String>, FfiSmbError> {
        run(async move {
            let c = SmbCredentials::from(creds);
            Ok(client().list_shares(&host, port, &c).await?)
        })
        .await
    }

    pub(crate) async fn open(
        account_id: String,
        target: FfiSmbTarget,
        creds: FfiSmbCredentials,
        path: String,
    ) -> Result<String, FfiSmbError> {
        run(async move {
            let server = SERVER
                .get_or_try_init(|| StreamServer::start(client()))
                .await
                .map_err(|e| FfiSmbError {
                    kind: FfiSmbErrorKind::Unreachable,
                    message: format!("cannot start the local SMB server: {e}"),
                })?;
            server
                .open(&account_id, target.into(), creds.into(), &path)
                .map_err(Into::into)
        })
        .await
    }

    #[allow(
        clippy::unused_async,
        reason = "keeps the signature the FFI wrapper and the wasm stub share"
    )]
    pub(crate) async fn close_account(account_id: String) -> Result<(), FfiSmbError> {
        // With no server there are no tokens and no tracked connections.
        // Connections that list/stat made for the account are not tracked per
        // account, so they close through the client's 60 s idle sweep.
        if let Some(server) = SERVER.get() {
            // Closing a connection can spawn its teardown, and this runs on the
            // Dart isolate thread, which has no reactor of its own.
            let _guard = runtime::enter();
            server.close_account(&account_id);
        }
        Ok(())
    }

    pub(crate) async fn heal_listener() -> Result<FfiHeal, FfiSmbError> {
        let Some(server) = SERVER.get().cloned() else {
            return Ok(FfiHeal::Healthy);
        };
        run(async move {
            let heal = server.heal().await.map_err(|e| FfiSmbError {
                kind: FfiSmbErrorKind::Unreachable,
                message: format!("cannot rebind the local SMB server: {e}"),
            })?;
            Ok(match heal {
                Heal::Healthy => FfiHeal::Healthy,
                Heal::ReboundSamePort => FfiHeal::ReboundSamePort,
                Heal::ReboundNewPort => FfiHeal::ReboundNewPort,
            })
        })
        .await
    }
}

#[cfg(target_arch = "wasm32")]
pub(crate) mod imp {
    use super::{
        FfiHeal, FfiSmbCredentials, FfiSmbEntry, FfiSmbError, FfiSmbErrorKind, FfiSmbTarget,
    };

    fn unsupported<T>() -> Result<T, FfiSmbError> {
        Err(FfiSmbError {
            kind: FfiSmbErrorKind::Unsupported,
            message: "SMB is not available in the browser".to_string(),
        })
    }

    pub(crate) async fn list(
        _target: FfiSmbTarget,
        _creds: FfiSmbCredentials,
        _dir: String,
    ) -> Result<Vec<FfiSmbEntry>, FfiSmbError> {
        unsupported()
    }

    pub(crate) async fn stat(
        _target: FfiSmbTarget,
        _creds: FfiSmbCredentials,
        _path: String,
    ) -> Result<Option<FfiSmbEntry>, FfiSmbError> {
        unsupported()
    }

    pub(crate) async fn probe(
        _target: FfiSmbTarget,
        _creds: FfiSmbCredentials,
        _root: String,
    ) -> Result<(), FfiSmbError> {
        unsupported()
    }

    pub(crate) async fn list_shares(
        _host: String,
        _port: u16,
        _creds: FfiSmbCredentials,
    ) -> Result<Vec<String>, FfiSmbError> {
        unsupported()
    }

    pub(crate) async fn open(
        _account_id: String,
        _target: FfiSmbTarget,
        _creds: FfiSmbCredentials,
        _path: String,
    ) -> Result<String, FfiSmbError> {
        unsupported()
    }

    pub(crate) async fn close_account(_account_id: String) -> Result<(), FfiSmbError> {
        unsupported()
    }

    pub(crate) async fn heal_listener() -> Result<FfiHeal, FfiSmbError> {
        unsupported()
    }
}
