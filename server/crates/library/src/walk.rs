use std::path::{Path, PathBuf};

use chrono::{DateTime, Utc};
use walkdir::WalkDir;

use crate::LibraryError;

/// The container extensions Mydia Server indexes. Identical to the Elixir
/// scanner's list (lib/mydia/library/scanner.ex:17) so both servers see the
/// same library.
pub const VIDEO_EXTENSIONS: &[&str] = &[
    "mkv", "mp4", "avi", "mov", "wmv", "flv", "webm", "m4v", "mpg", "mpeg", "m2ts", "ts",
];

/// Directory names whose contents are not the feature. Matched case
/// insensitively against the directory's own name.
const EXCLUDED_DIRECTORIES: &[&str] = &[
    "sample",
    "samples",
    "trailer",
    "trailers",
    "extras",
    "featurette",
    "featurettes",
    "behind the scenes",
    "deleted scenes",
    "interviews",
    "scenes",
    "shorts",
    "other",
];

#[derive(Debug, Clone)]
pub struct VideoFile {
    pub path: PathBuf,
    pub size: u64,
    pub mtime: DateTime<Utc>,
}

/// Lists candidate media files under `root`, recursively and in path order.
///
/// Entries that cannot be read are skipped rather than aborting the walk,
/// because one unreadable directory on a network mount must not hide the rest
/// of the library. A root that is not a directory is an error, because that
/// is a configuration mistake the operator needs told about.
pub fn walk(root: &Path) -> Result<Vec<VideoFile>, LibraryError> {
    if !root.is_dir() {
        return Err(LibraryError::Walk {
            path: root.display().to_string(),
            source: std::io::Error::new(
                std::io::ErrorKind::NotFound,
                "the path is not a directory",
            ),
        });
    }

    let mut found = Vec::new();

    let walker = WalkDir::new(root)
        .follow_links(false)
        .into_iter()
        .filter_entry(|entry| {
            // The root itself is always entered, whatever it is called.
            if entry.depth() == 0 {
                return true;
            }

            let name = entry.file_name().to_string_lossy();

            if name.starts_with('.') {
                return false;
            }

            if entry.file_type().is_dir() {
                return !EXCLUDED_DIRECTORIES.contains(&name.to_lowercase().as_str());
            }

            true
        });

    for entry in walker {
        let Ok(entry) = entry else {
            continue;
        };

        if !entry.file_type().is_file() {
            continue;
        }

        let path = entry.path();

        if !has_video_extension(path) || looks_like_a_sample(path) {
            continue;
        }

        let Ok(metadata) = entry.metadata() else {
            continue;
        };

        let mtime = metadata
            .modified()
            .ok()
            .map(DateTime::<Utc>::from)
            .unwrap_or_else(Utc::now);

        found.push(VideoFile {
            path: path.to_path_buf(),
            size: metadata.len(),
            mtime,
        });
    }

    found.sort_by(|a, b| a.path.cmp(&b.path));

    Ok(found)
}

fn has_video_extension(path: &Path) -> bool {
    path.extension()
        .and_then(|e| e.to_str())
        .map(|e| VIDEO_EXTENSIONS.contains(&e.to_lowercase().as_str()))
        .unwrap_or(false)
}

/// A file whose stem carries a sample marker as its own token, separated by
/// the punctuation release names use ("-", "_", "."). Splitting on every
/// non-alphanumeric character (including spaces) would turn "The Sample
/// Room (2019)" into the token "sample" and drop a real film; splitting only
/// on separator punctuation keeps natural-language titles intact while still
/// catching "Movie-sample" and "sample-Movie".
fn looks_like_a_sample(path: &Path) -> bool {
    let Some(stem) = path.file_stem().and_then(|s| s.to_str()) else {
        return false;
    };

    stem.to_lowercase()
        .split(['-', '_', '.'])
        .any(|token| token.trim() == "sample")
}

#[cfg(test)]
mod tests {
    use super::walk;
    use std::fs;
    use std::path::Path;

    fn touch(root: &Path, relative: &str) {
        let path = root.join(relative);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, b"not really a video").unwrap();
    }

    #[test]
    fn video_files_are_found_recursively() {
        let dir = tempfile::tempdir().unwrap();
        touch(dir.path(), "The Matrix (1999)/The Matrix (1999).mkv");
        touch(dir.path(), "Show/Season 01/Show - S01E01.mp4");

        assert_eq!(walk(dir.path()).unwrap().len(), 2);
    }

    #[test]
    fn non_video_files_are_ignored() {
        let dir = tempfile::tempdir().unwrap();
        touch(dir.path(), "Movie (2020)/Movie (2020).mkv");
        touch(dir.path(), "Movie (2020)/poster.jpg");
        touch(dir.path(), "Movie (2020)/Movie (2020).nfo");
        touch(dir.path(), "Movie (2020)/Movie (2020).en.srt");

        assert_eq!(walk(dir.path()).unwrap().len(), 1);
    }

    #[test]
    fn sample_and_extras_directories_are_skipped() {
        let dir = tempfile::tempdir().unwrap();
        touch(dir.path(), "Movie (2020)/Movie (2020).mkv");
        touch(dir.path(), "Movie (2020)/Sample/sample.mkv");
        touch(dir.path(), "Movie (2020)/Featurettes/making-of.mkv");
        touch(dir.path(), "Movie (2020)/Trailers/trailer.mkv");

        let found = walk(dir.path()).unwrap();
        assert_eq!(found.len(), 1, "got {found:?}");
    }

    #[test]
    fn files_named_as_samples_are_skipped() {
        let dir = tempfile::tempdir().unwrap();
        touch(dir.path(), "Movie (2020)/Movie (2020).mkv");
        touch(dir.path(), "Movie (2020)/Movie (2020)-sample.mkv");
        touch(dir.path(), "Movie (2020)/sample-Movie.mkv");

        let found = walk(dir.path()).unwrap();
        assert_eq!(found.len(), 1, "got {found:?}");
    }

    #[test]
    fn a_film_whose_title_contains_sample_survives() {
        let dir = tempfile::tempdir().unwrap();
        touch(
            dir.path(),
            "The Sample Room (2019)/The Sample Room (2019).mkv",
        );

        // Token matching, not substring matching: "Sample Room" is a title,
        // "Movie-sample" is a sample.
        assert_eq!(walk(dir.path()).unwrap().len(), 1);
    }

    #[test]
    fn hidden_directories_and_appledouble_files_are_skipped() {
        let dir = tempfile::tempdir().unwrap();
        touch(dir.path(), "Movie (2020)/Movie (2020).mkv");
        touch(dir.path(), ".Trash/deleted.mkv");
        touch(dir.path(), "Movie (2020)/._Movie (2020).mkv");

        let found = walk(dir.path()).unwrap();
        assert_eq!(found.len(), 1, "got {found:?}");
    }

    #[test]
    fn size_and_mtime_are_reported() {
        let dir = tempfile::tempdir().unwrap();
        touch(dir.path(), "Movie (2020)/Movie (2020).mkv");

        let found = walk(dir.path()).unwrap();

        assert_eq!(found[0].size, b"not really a video".len() as u64);
        assert!(found[0].mtime.timestamp() > 0);
    }

    #[test]
    fn results_are_sorted_by_path() {
        let dir = tempfile::tempdir().unwrap();
        touch(dir.path(), "B.mkv");
        touch(dir.path(), "A.mkv");

        let found = walk(dir.path()).unwrap();

        assert!(found[0].path < found[1].path);
    }

    #[test]
    fn a_missing_root_is_an_error_not_an_empty_list() {
        let dir = tempfile::tempdir().unwrap();

        assert!(walk(&dir.path().join("nope")).is_err());
    }
}
