//! Thin facade over the release parser, matching the call sites that
//! just need a `ParsedFileInfo` from a path. Mirrors the public shape
//! of `lib/mydia/library/file_parser.ex`.
//!
//! The Phoenix module's V2 regex-based parser still lives behind a
//! feature flag; this Rust port routes directly to the V3 parser in
//! [`crate::release_parser`], which is the path U17 / U22 callers
//! will use.

use crate::release_parser::{ParseOptions, ParsedFileInfo, ReleaseParser, TargetContext};

/// Public facade. Mirrors `Mydia.Library.FileParser`.
#[derive(Debug, Default, Clone, Copy)]
pub struct FileParser;

impl FileParser {
    /// Parse a filename (or full path; we strip to basename
    /// internally).
    #[must_use]
    pub fn parse(filename: &str) -> ParsedFileInfo {
        ReleaseParser::parse(filename)
    }

    /// Parse with a target binding (the caller has already matched
    /// the file to a media item and wants the parser to lock the
    /// title / kind / year).
    #[must_use]
    pub fn parse_with_target(filename: &str, target: TargetContext) -> ParsedFileInfo {
        ReleaseParser::parse_with_opts(
            filename,
            &ParseOptions {
                target: Some(target),
            },
        )
    }
}
