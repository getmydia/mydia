//! Everything between the filesystem and the database: the read-only walk,
//! the filename parser, ffprobe, grouping, and the scan orchestrator.
//!
//! This crate never writes inside a library path. It reads directory entries,
//! calls stat, and opens files for reading through ffprobe. Nothing else.

pub mod ffprobe;
pub mod names;
pub mod parser;
pub mod walk;

#[derive(Debug, thiserror::Error)]
pub enum LibraryError {
    #[error("could not read the library path `{path}`: {source}")]
    Walk {
        path: String,
        #[source]
        source: std::io::Error,
    },

    #[error("could not run ffprobe on `{path}`: {detail}")]
    Ffprobe { path: String, detail: String },

    #[error("ffprobe returned output that could not be read for `{path}`: {detail}")]
    FfprobeOutput { path: String, detail: String },
}
