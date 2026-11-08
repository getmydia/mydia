//! SMB2/3 client for the player's files library.
//!
//! Paths are share-relative, `/`-separated, and start with `/` (the share
//! root is `/`).

/// Where a share lives.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SmbTarget {
    pub host: String,
    pub port: u16,
    pub share: String,
}

/// Login for a share. An empty `user` means guest.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SmbCredentials {
    pub user: String,
    pub password: String,
    pub domain: Option<String>,
}

/// One directory entry.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SmbEntry {
    pub path: String,
    pub name: String,
    pub is_dir: bool,
    pub size: u64,
    pub modified_ms: i64,
    pub unreadable: bool,
}

#[derive(thiserror::Error, Debug)]
pub enum SmbError {
    #[error("unreachable: {0}")]
    Unreachable(String),
    #[error("unauthorized")]
    Unauthorized,
    #[error("not found")]
    NotFound,
    #[error("smb1 only")]
    Smb1Only,
    #[error("{0}")]
    Other(String),
}

/// What a reconnect attempt did to the server binding.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Heal {
    Healthy,
    ReboundSamePort,
    ReboundNewPort,
}
