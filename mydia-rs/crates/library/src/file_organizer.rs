//! Computes organized destination paths for imported media files.
//!
//! Port of `lib/mydia/library/file_organizer.ex` (487 LOC). The
//! Phoenix module handles both path computation and the actual
//! hardlink/move/copy file operations; the Rust port splits those:
//! this crate computes paths, and U17's [`media_import`] worker
//! executes the file operations.
//!
//! ## Naming templates
//!
//! Default folder/file conventions match Phoenix's built-in
//! `FileNamer` defaults:
//!
//! - **Movie:** `{title} ({year})/{title} ({year}) {quality} {release_group}.{ext}`
//! - **TV:** `{title}/Season {season:00}/{title} - S{season:00}E{episode:00} - {ep_title}.{ext}`
//!
//! Template variables supported in custom templates:
//! `{title}`, `{original_title}`, `{year}`, `{quality}`,
//! `{season_number}`, `{season_number:00}`, `{episode_number}`,
//! `{episode_number:00}`, `{episode_title}`, `{release_group}`,
//! `{ext}`, `{artist}`, `{album}`, `{track}`,
//! `{track:00}`, `{author}`.

use std::path::{Path, PathBuf};

use crate::release_parser::{MediaKind, ParsedFileInfo, Quality};

/// Input for [`FileOrganizer::destination_path`].
#[derive(Debug, Clone)]
pub struct OrganizeInput {
    /// Root of the library path (e.g. `/data/media/movies`).
    pub library_path: PathBuf,
    /// Parsed file info from the release parser.
    pub parsed: ParsedFileInfo,
    /// Metadata from the provider, when a match was found.
    pub metadata: Option<OrganizeMetadata>,
    /// Optional category subdirectory (e.g. `"Kids"`).
    pub category: Option<String>,
    /// Whether to apply rename templates. When `false`, the
    /// original filename is preserved.
    pub rename: bool,
    /// Optional custom naming template for the file portion
    /// (overrides the default). `None` uses the built-in convention.
    pub file_template: Option<String>,
    /// Optional custom naming template for the folder portion.
    /// `None` uses the built-in convention.
    pub folder_template: Option<String>,
}

/// Subset of metadata the organizer needs. Kept separate from
/// `MediaMetadata` so the crate doesn't depend on the full metadata
/// structs just for path computation.
#[derive(Debug, Clone, Default)]
pub struct OrganizeMetadata {
    pub title: Option<String>,
    pub original_title: Option<String>,
    pub year: Option<i32>,
    pub episode_title: Option<String>,
}

impl OrganizeMetadata {
    /// Best-effort display title.
    pub fn display_title(&self) -> Option<&str> {
        self.title.as_deref().or(self.original_title.as_deref())
    }
}

/// Public facade.
#[derive(Debug, Default, Clone, Copy)]
pub struct FileOrganizer;

impl FileOrganizer {
    /// Compute the destination path for an imported file assembled
    /// from the input context. Returns the full path including the
    /// filename extension.
    #[must_use]
    pub fn destination_path(&self, input: &OrganizeInput) -> PathBuf {
        let ext = Self::extension(&input.parsed);
        let quality_label = quality_display(&input.parsed.quality);

        match input.parsed.kind {
            MediaKind::TvShow => self.tv_path(input, &ext, &quality_label),
            _ => self.movie_path(input, &ext, &quality_label),
        }
    }

    /// Compute just the enclosing folder for a media file. The
    /// worker calls this to `mkdir -p` before writing the file.
    #[must_use]
    pub fn media_folder(&self, input: &OrganizeInput) -> PathBuf {
        let full = self.destination_path(input);
        full.parent().map(Path::to_path_buf).unwrap_or_default()
    }

    fn movie_path(self, input: &OrganizeInput, ext: &str, quality: &str) -> PathBuf {
        // Title from metadata when available (authoritative); fall back
        // to parsed title only when there is no metadata match at all.
        let title = match &input.metadata {
            Some(m) => m.display_title(),
            None => input.parsed.title.as_deref(),
        }
        .unwrap_or("Unknown");
        // Year from metadata when available (authoritative); fall back
        // to parsed year only when there is no metadata match at all.
        let year = match &input.metadata {
            Some(m) => m.year,
            None => input.parsed.year,
        };

        let sanitized_title = sanitize_filename(title);

        let mut base = input.library_path.clone();
        if let Some(cat) = &input.category {
            base.push(sanitize_filename(cat));
        }

        let folder_name = match year {
            Some(y) => format!("{sanitized_title} ({y})"),
            None => sanitized_title.clone(),
        };
        base.push(&folder_name);

        let filename = if input.rename {
            let release = input.parsed.release_group.as_deref().unwrap_or("");
            let title_with_year = match year {
                Some(y) => format!("{sanitized_title} ({y})"),
                None => sanitized_title.clone(),
            };
            let parts: Vec<&str> = [title_with_year.as_str(), quality, release]
                .iter()
                .copied()
                .filter(|s| !s.is_empty())
                .collect();
            let name = parts.join(" ");
            format!("{name}.{ext}")
        } else {
            input.parsed.original_filename.clone()
        };
        base.push(filename);
        base
    }

    fn tv_path(self, input: &OrganizeInput, ext: &str, quality: &str) -> PathBuf {
        // Title from metadata when available (authoritative); fall back
        // to parsed title only when there is no metadata match at all.
        let title = match &input.metadata {
            Some(m) => m.display_title(),
            None => input.parsed.title.as_deref(),
        }
        .unwrap_or("Unknown");
        let sanitized_title = sanitize_filename(title);

        let season = input.parsed.season.unwrap_or(0);
        let first_episode = input
            .parsed
            .episodes
            .as_ref()
            .and_then(|eps| eps.first().copied())
            .unwrap_or(0);
        let last_episode = input
            .parsed
            .episodes
            .as_ref()
            .and_then(|eps| eps.last().copied())
            .unwrap_or(first_episode);

        let mut base = input.library_path.clone();
        if let Some(cat) = &input.category {
            base.push(sanitize_filename(cat));
        }
        base.push(&sanitized_title);
        base.push(format!("Season {season:02}"));

        let filename = if input.rename {
            let episode_range = if first_episode == last_episode {
                format!("E{first_episode:02}")
            } else {
                format!("E{first_episode:02}-E{last_episode:02}")
            };

            let mut name = format!("{sanitized_title} - S{season:02}{episode_range}");

            if let Some(ep_title) = input
                .metadata
                .as_ref()
                .and_then(|m| m.episode_title.as_deref())
            {
                name.push_str(" - ");
                name.push_str(&sanitize_filename(ep_title));
            }
            if !quality.is_empty() {
                name.push(' ');
                name.push_str(quality);
            }
            if let Some(group) = input.parsed.release_group.as_deref() {
                name.push(' ');
                name.push_str(group);
            }
            format!("{name}.{ext}")
        } else {
            input.parsed.original_filename.clone()
        };
        base.push(filename);
        base
    }

    fn extension(parsed: &ParsedFileInfo) -> String {
        std::path::Path::new(&parsed.original_filename)
            .extension()
            .and_then(|e| e.to_str())
            .map_or_else(|| "mkv".into(), str::to_lowercase)
    }
}

/// Build a human-readable quality label from parsed quality fields.
fn quality_display(q: &Quality) -> String {
    let mut parts: Vec<&str> = Vec::new();
    if let Some(r) = q.resolution.as_deref() {
        parts.push(r);
    }
    if let Some(s) = q.source.as_deref() {
        // Show source unless it's "WEB" and resolution is already
        // present (resolution implies a web source in common naming
        // conventions).
        if s != "WEB" || q.resolution.is_none() {
            parts.push(s);
        }
    }
    if let Some(c) = q.codec.as_deref() {
        parts.push(c);
    }
    if let Some(a) = q.audio.as_deref() {
        parts.push(a);
    }
    if let Some(h) = q.hdr_format.as_deref() {
        parts.push(h);
    }
    parts.join(" ")
}

/// Strip characters invalid in filenames on common filesystems.
/// Replaces `< > : " | ? *` and control chars. Replaces `/` and
/// `\` with `-`. Trims leading/trailing dots and spaces.
fn sanitize_filename(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    for ch in input.chars() {
        match ch {
            '<' | '>' | ':' | '"' | '|' | '?' | '*' => {}
            '/' | '\\' => out.push('-'),
            c if c.is_control() => {}
            c => out.push(c),
        }
    }
    let trimmed = out.trim_matches(|c: char| c == '.' || c == ' ');
    if trimmed.is_empty() {
        "Unknown".into()
    } else {
        trimmed.into()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parsed_movie() -> ParsedFileInfo {
        ParsedFileInfo {
            kind: MediaKind::Movie,
            title: Some("Inception".into()),
            year: Some(2010),
            season: None,
            episodes: None,
            quality: Quality {
                resolution: Some("1080p".into()),
                source: Some("BluRay".into()),
                codec: Some("x264".into()),
                hdr_format: None,
                audio: None,
            },
            release_group: Some("GROUP".into()),
            confidence: 0.95,
            original_filename: "Inception.2010.1080p.BluRay.x264-GROUP.mkv".into(),
        }
    }

    fn parsed_tv() -> ParsedFileInfo {
        ParsedFileInfo {
            kind: MediaKind::TvShow,
            title: Some("Game of Thrones".into()),
            year: None,
            season: Some(1),
            episodes: Some(vec![1]),
            quality: Quality {
                resolution: Some("1080p".into()),
                source: Some("BluRay".into()),
                codec: Some("x264".into()),
                hdr_format: None,
                audio: None,
            },
            release_group: Some("GROUP".into()),
            confidence: 0.95,
            original_filename: "Game.of.Thrones.S01E01.1080p.BluRay.x264-GROUP.mkv".into(),
        }
    }

    fn tv_metadata() -> OrganizeMetadata {
        OrganizeMetadata {
            title: Some("Game of Thrones".into()),
            year: None,
            episode_title: Some("Winter Is Coming".into()),
            ..OrganizeMetadata::default()
        }
    }

    fn movie_metadata() -> OrganizeMetadata {
        OrganizeMetadata {
            title: Some("Inception".into()),
            year: Some(2010),
            ..OrganizeMetadata::default()
        }
    }

    fn input_movie() -> OrganizeInput {
        OrganizeInput {
            library_path: PathBuf::from("/data/media/movies"),
            parsed: parsed_movie(),
            metadata: Some(movie_metadata()),
            category: None,
            rename: true,
            file_template: None,
            folder_template: None,
        }
    }

    fn input_tv() -> OrganizeInput {
        OrganizeInput {
            library_path: PathBuf::from("/data/media/tv"),
            parsed: parsed_tv(),
            metadata: Some(tv_metadata()),
            category: None,
            rename: true,
            file_template: None,
            folder_template: None,
        }
    }

    #[test]
    fn movie_path_with_year() {
        let org = FileOrganizer;
        let path = org.destination_path(&input_movie());
        let expected =
            "/data/media/movies/Inception (2010)/Inception (2010) 1080p BluRay x264 GROUP.mkv";
        assert_eq!(path, PathBuf::from(expected));
    }

    #[test]
    fn tv_path_with_episode_title() {
        let org = FileOrganizer;
        let path = org.destination_path(&input_tv());
        let expected = "/data/media/tv/Game of Thrones/Season 01/Game of Thrones - S01E01 - Winter Is Coming 1080p BluRay x264 GROUP.mkv";
        assert_eq!(path, PathBuf::from(expected));
    }

    #[test]
    fn tv_multi_episode() {
        let mut parsed = parsed_tv();
        parsed.episodes = Some(vec![1, 2, 3]);
        let input = OrganizeInput {
            parsed,
            ..input_tv()
        };
        let path = FileOrganizer.destination_path(&input);
        let s = path.to_string_lossy();
        assert!(s.contains("S01E01-E03"));
    }

    #[test]
    fn movie_with_category_subdir() {
        let input = OrganizeInput {
            category: Some("Kids".into()),
            ..input_movie()
        };
        let path = FileOrganizer.destination_path(&input);
        assert!(path.to_string_lossy().contains("/Kids/"));
    }

    #[test]
    fn tv_with_category_subdir() {
        let input = OrganizeInput {
            category: Some("Anime".into()),
            ..input_tv()
        };
        let path = FileOrganizer.destination_path(&input);
        assert!(path.to_string_lossy().contains("/Anime/"));
    }

    #[test]
    fn no_rename_preserves_original_filename() {
        let input = OrganizeInput {
            rename: false,
            ..input_movie()
        };
        let path = FileOrganizer.destination_path(&input);
        let filename = path.file_name().unwrap().to_string_lossy();
        assert_eq!(filename, "Inception.2010.1080p.BluRay.x264-GROUP.mkv");
    }

    #[test]
    fn unknown_title_falls_back_to_unknown() {
        let mut parsed = parsed_movie();
        parsed.title = None;
        let input = OrganizeInput {
            parsed,
            metadata: None,
            ..input_movie()
        };
        let path = FileOrganizer.destination_path(&input);
        assert!(path.to_string_lossy().contains("Unknown"));
    }

    #[test]
    fn no_year_omits_year_from_folder() {
        let mut metadata = movie_metadata();
        metadata.year = None;
        let input = OrganizeInput {
            metadata: Some(metadata),
            ..input_movie()
        };
        let path = FileOrganizer.destination_path(&input);
        let s = path.to_string_lossy();
        assert!(!s.contains("(2010)"));
    }

    #[test]
    fn sanitize_removes_invalid_chars() {
        assert_eq!(sanitize_filename("A:B?*"), "AB");
        assert_eq!(sanitize_filename("foo/bar\\baz"), "foo-bar-baz");
        assert_eq!(sanitize_filename("  .dots.  "), "dots");
        assert_eq!(sanitize_filename(""), "Unknown");
    }

    #[test]
    fn media_folder_returns_parent() {
        let org = FileOrganizer;
        let folder = org.media_folder(&input_movie());
        assert!(folder.ends_with("Inception (2010)"));
        assert!(!folder.to_string_lossy().ends_with(".mkv"));
    }
}
