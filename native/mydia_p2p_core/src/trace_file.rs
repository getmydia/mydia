//! Opt-in trace file for debugging the transport on a running server.
//!
//! The NIF's only log output is `ElixirLogLayer`, which goes through the
//! Elixir Logger. That path cannot carry a QUIC trace: the Logger level drops
//! `debug` and `trace`, and the layer keeps only each event's message, losing
//! the span context (`path_id`, packet number, connection) that makes a noq
//! trace readable.
//!
//! Setting `MYDIA_P2P_TRACE_FILE` adds a second layer that writes full
//! `tracing` output, spans included, to that file. `MYDIA_P2P_TRACE` sets its
//! filter (default [`DEFAULT_FILTER`]). The file rotates once it passes
//! `MYDIA_P2P_TRACE_MAX_BYTES` (default 512 MiB): the current file becomes
//! `<path>.1`, replacing the previous one, so at most twice the cap is kept.
//!
//! Unset, nothing is installed and nothing changes.

use std::fs::{File, OpenOptions};
use std::io::{self, Write};
use std::path::PathBuf;
use std::sync::Mutex;

use tracing_subscriber::{registry::LookupSpan, EnvFilter, Layer};

const DEFAULT_FILTER: &str = "info,mydia_p2p_core=debug,iroh=debug,noq_proto=trace,noq=debug";
const DEFAULT_MAX_BYTES: u64 = 512 * 1024 * 1024;

/// The trace file layer, if `MYDIA_P2P_TRACE_FILE` is set and the file opens.
pub(crate) fn layer<S>() -> Option<impl Layer<S>>
where
    S: tracing::Subscriber + for<'a> LookupSpan<'a>,
{
    let path = PathBuf::from(std::env::var_os("MYDIA_P2P_TRACE_FILE")?);
    let max_bytes = std::env::var("MYDIA_P2P_TRACE_MAX_BYTES")
        .ok()
        .and_then(|v| v.parse().ok())
        // Zero would rotate on every write.
        .filter(|&bytes| bytes > 0)
        .unwrap_or(DEFAULT_MAX_BYTES);
    let filter = std::env::var("MYDIA_P2P_TRACE")
        .ok()
        .and_then(|v| EnvFilter::try_new(v).ok())
        .unwrap_or_else(|| EnvFilter::new(DEFAULT_FILTER));

    let writer = match RotatingFile::open(path.clone(), max_bytes) {
        Ok(writer) => writer,
        Err(e) => {
            // No subscriber is installed yet, so this is the only place the
            // failure can be reported.
            #[expect(
                clippy::print_stderr,
                reason = "runs before any tracing subscriber exists"
            )]
            {
                eprintln!(
                    "mydia_p2p_core: cannot open trace file {}: {e}",
                    path.display()
                );
            }
            return None;
        }
    };

    Some(
        tracing_subscriber::fmt::layer()
            .with_ansi(false)
            .with_thread_ids(true)
            .with_writer(Mutex::new(writer))
            .with_filter(filter),
    )
}

/// An append-only file that moves itself to `<path>.1` past `max_bytes`.
struct RotatingFile {
    path: PathBuf,
    file: File,
    written: u64,
    max_bytes: u64,
}

impl RotatingFile {
    fn open(path: PathBuf, max_bytes: u64) -> io::Result<Self> {
        let file = OpenOptions::new().create(true).append(true).open(&path)?;
        let written = file.metadata()?.len();
        Ok(Self {
            path,
            file,
            written,
            max_bytes,
        })
    }

    fn rotate(&mut self) -> io::Result<()> {
        self.file.flush()?;
        let mut rotated = self.path.clone().into_os_string();
        rotated.push(".1");
        std::fs::rename(&self.path, rotated)?;
        self.file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.path)?;
        self.written = 0;
        Ok(())
    }
}

impl Write for RotatingFile {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        if self.written >= self.max_bytes {
            // A file that cannot rotate stops growing: losing the rest of a
            // trace is better than filling a server's disk. The next write
            // tries the rotation again.
            self.rotate()?;
        }
        let n = self.file.write(buf)?;
        self.written = self.written.saturating_add(n as u64);
        Ok(n)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.file.flush()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rotates_past_the_cap_and_keeps_one_previous_file() {
        let dir = std::env::temp_dir().join(format!("mydia_trace_file_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("temp dir");
        let path = dir.join("trace.log");

        let mut file = RotatingFile::open(path.clone(), 10).expect("open");
        file.write_all(b"0123456789").expect("first write");
        file.write_all(b"abc").expect("second write rotates");
        file.flush().expect("flush");

        let rotated = std::fs::read(dir.join("trace.log.1")).expect("rotated file");
        let current = std::fs::read(&path).expect("current file");
        assert_eq!(rotated, b"0123456789");
        assert_eq!(current, b"abc");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_reopened_file_counts_its_existing_size_and_replaces_the_old_backup() {
        let dir = std::env::temp_dir().join(format!("mydia_trace_reopen_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("temp dir");
        let path = dir.join("trace.log");
        std::fs::write(&path, b"0123456789").expect("existing trace");
        std::fs::write(dir.join("trace.log.1"), b"stale").expect("stale backup");

        let mut file = RotatingFile::open(path.clone(), 10).expect("open");
        file.write_all(b"new").expect("write rotates at once");
        file.flush().expect("flush");

        assert_eq!(
            std::fs::read(dir.join("trace.log.1")).expect("backup"),
            b"0123456789"
        );
        assert_eq!(std::fs::read(&path).expect("current"), b"new");

        let _ = std::fs::remove_dir_all(&dir);
    }
}
