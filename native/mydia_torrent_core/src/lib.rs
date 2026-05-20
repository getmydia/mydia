use std::sync::Arc;
use std::path::PathBuf;
use anyhow::{Result, Context};
use librqbit::{Session, SessionOptions, AddTorrentOptions, AddTorrentResponse, AddTorrent};
use librqbit::api::TorrentIdOrHash;
use tokio::io::{AsyncReadExt, AsyncSeekExt, SeekFrom};

pub struct Engine {
    session: Arc<Session>,
}

pub struct TorrentHandle {
    pub id: usize,
    pub info_hash: String,
}

impl Engine {
    pub async fn new(staging_dir: String) -> Result<Self> {
        let opts = SessionOptions {
            persistence: None,
            disable_dht_persistence: true,
            ..Default::default()
        };
        
        let session = Session::new_with_opts(PathBuf::from(staging_dir), opts)
            .await
            .context("Failed to create librqbit session")?;
            
        Ok(Self {
            session,
        })
    }

    pub async fn add_magnet(&self, magnet: &str) -> Result<AddTorrentResponse> {
        let opts = AddTorrentOptions {
            ..Default::default()
        };
        
        self.session.add_torrent(AddTorrent::from_url(magnet), Some(opts))
            .await
            .context("Failed to add magnet")
    }

    pub async fn delete_torrent(&self, id: usize, delete_files: bool) -> Result<()> {
        self.session.delete(TorrentIdOrHash::Id(id), delete_files)
            .await
            .context("Failed to delete torrent")
    }

    pub async fn read_chunk(&self, torrent_id: usize, file_id: usize, offset: u64, len: usize) -> Result<Vec<u8>> {
        let torrent = self.session.get(TorrentIdOrHash::Id(torrent_id)).context("Torrent not found")?;
        let mut stream = torrent.stream(file_id).context("Failed to open stream")?;
        
        stream.seek(SeekFrom::Start(offset)).await.context("Failed to seek")?;
        
        let mut buf = vec![0u8; len];
        let n = stream.read(&mut buf).await.context("Failed to read")?;
        buf.truncate(n);
        
        Ok(buf)
    }

    pub fn session(&self) -> Arc<Session> {
        self.session.clone()
    }
}
