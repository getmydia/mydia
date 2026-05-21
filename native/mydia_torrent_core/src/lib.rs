use std::sync::Arc;
use std::path::PathBuf;
use std::time::Duration;
use anyhow::{Result, Context};
use librqbit::{Session, SessionOptions, AddTorrentOptions, AddTorrentResponse, AddTorrent};
use librqbit::api::TorrentIdOrHash;
use tokio::io::{AsyncReadExt, AsyncSeekExt, SeekFrom};

/// Cap on how long add_torrent will wait for metadata to resolve before
/// giving up. A bare add_torrent without this timeout will spin indefinitely
/// for magnets with no peers, leaking the librqbit handle.
const ADD_TORRENT_METADATA_TIMEOUT: Duration = Duration::from_secs(25);

/// Cap on a single read_chunk's wait for buffered data. A slow/missing peer
/// otherwise wedges the Session GenServer for the full call timeout (60s).
const READ_CHUNK_TIMEOUT: Duration = Duration::from_secs(5);

pub struct Engine {
    session: Arc<Session>,
    staging_dir: PathBuf,
}

pub struct AddedTorrent {
    pub result_type: &'static str,
    pub torrent_id: usize,
    pub info_hash: String,
    pub file_id: usize,
    pub staging_path: String,
    pub total_bytes: u64,
}

impl Engine {
    pub async fn new(staging_dir: String) -> Result<Self> {
        let opts = SessionOptions {
            persistence: None,
            disable_dht_persistence: true,
            ..Default::default()
        };
        
        let staging_path = PathBuf::from(staging_dir);
        let session = Session::new_with_opts(staging_path.clone(), opts)
            .await
            .context("Failed to create librqbit session")?;
            
        Ok(Self {
            session,
            staging_dir: staging_path,
        })
    }

    pub async fn add_magnet(&self, magnet: &str) -> Result<AddedTorrent> {
        let opts = AddTorrentOptions {
            ..Default::default()
        };

        let response = self
            .session
            .add_torrent(AddTorrent::from_url(magnet), Some(opts))
            .await
            .context("Failed to add magnet")?;

        let (result_type, torrent_id, handle) = match response {
            AddTorrentResponse::AlreadyManaged(t_id, handle) => ("already_exists", t_id, handle),
            AddTorrentResponse::Added(t_id, handle) => ("added", t_id, handle),
            _ => anyhow::bail!("unsupported response"),
        };

        let output_folder = self.staging_dir.clone();

        // Resolve metadata. `with_metadata` blocks until librqbit has fetched
        // the torrent info from peers. We spawn it on the blocking pool and
        // race it against `ADD_TORRENT_METADATA_TIMEOUT` so a magnet with no
        // peers does not leak the librqbit task indefinitely.
        let metadata_handle = handle.clone();
        let metadata_folder = output_folder.clone();
        let metadata_join = tokio::task::spawn_blocking(move || {
            metadata_handle.with_metadata(|metadata| {
                let file_id = metadata
                    .file_infos
                    .iter()
                    .enumerate()
                    .max_by_key(|(_, file)| file.len)
                    .map(|(index, _)| index)
                    .context("torrent does not contain any files")?;

                let file = metadata
                    .file_infos
                    .get(file_id)
                    .context("selected file index is out of bounds")?;

                Ok::<_, anyhow::Error>((
                    file_id,
                    metadata_folder.join(&file.relative_filename),
                    file.len,
                ))
            })
        });

        let selected_file = match tokio::time::timeout(ADD_TORRENT_METADATA_TIMEOUT, metadata_join)
            .await
        {
            // Layers: timeout outer, JoinHandle, with_metadata outer, closure result.
            Ok(Ok(Ok(Ok(tuple)))) => tuple,
            Ok(Ok(Ok(Err(callback_err)))) => return Err(callback_err),
            Ok(Ok(Err(metadata_err))) => {
                return Err(anyhow::anyhow!(
                    "with_metadata returned error: {:?}",
                    metadata_err
                ))
            }
            Ok(Err(join_err)) => {
                return Err(anyhow::anyhow!("metadata task panicked: {:?}", join_err))
            }
            Err(_elapsed) => {
                // Time out: best-effort drop the leaked librqbit task so it
                // does not keep spinning forever.
                let _ = self
                    .session
                    .delete(TorrentIdOrHash::Id(torrent_id), true)
                    .await;

                anyhow::bail!(
                    "metadata resolution timed out after {:?}",
                    ADD_TORRENT_METADATA_TIMEOUT
                );
            }
        };

        Ok(AddedTorrent {
            result_type,
            torrent_id,
            info_hash: hex::encode(handle.info_hash().0),
            file_id: selected_file.0,
            staging_path: selected_file.1.to_string_lossy().into_owned(),
            total_bytes: selected_file.2,
        })
    }

    pub async fn delete_torrent(&self, id: usize, delete_files: bool) -> Result<()> {
        self.session.delete(TorrentIdOrHash::Id(id), delete_files)
            .await
            .context("Failed to delete torrent")
    }

    /// Cancel a torrent by infohash. Used by Session.terminate when metadata
    /// resolution never completed and we never received a torrent_id — without
    /// this path the librqbit task leaks until process exit.
    ///
    /// Accepts the canonical 40-char hex infohash.
    pub async fn delete_torrent_by_infohash(&self, info_hash: &str, delete_files: bool) -> Result<()> {
        let id = TorrentIdOrHash::parse(info_hash)
            .with_context(|| format!("invalid infohash: {}", info_hash))?;
        self.session.delete(id, delete_files)
            .await
            .context("Failed to delete torrent by infohash")
    }

    pub async fn read_chunk(&self, torrent_id: usize, file_id: usize, offset: u64, len: usize) -> Result<Vec<u8>> {
        let torrent = self.session.get(TorrentIdOrHash::Id(torrent_id)).context("Torrent not found")?;
        let mut stream = torrent.stream(file_id).context("Failed to open stream")?;

        // Time out the actual read so a slow/missing peer cannot wedge the
        // Session GenServer for the full 60s call timeout.
        let read_result = tokio::time::timeout(READ_CHUNK_TIMEOUT, async move {
            stream.seek(SeekFrom::Start(offset)).await.context("Failed to seek")?;

            let mut buf = vec![0u8; len];
            let n = stream.read(&mut buf).await.context("Failed to read")?;
            buf.truncate(n);

            Ok::<_, anyhow::Error>(buf)
        })
        .await;

        match read_result {
            Ok(Ok(buf)) => Ok(buf),
            Ok(Err(e)) => Err(e),
            Err(_elapsed) => {
                anyhow::bail!("read_chunk timed out after {:?} (slow or missing peer)", READ_CHUNK_TIMEOUT)
            }
        }
    }

    pub fn session(&self) -> Arc<Session> {
        self.session.clone()
    }
}
