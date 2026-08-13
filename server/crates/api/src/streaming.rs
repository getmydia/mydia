//! Turns a content type and id into a file, and a file into the candidate
//! result the contract declares.

use async_graphql::{Error, ID};
use mydia_db::media_files::MediaFileRow;
use mydia_db::Db;
use mydia_library::ranking;
use mydia_streaming::candidates::{build, Candidate, Facts, Strategy};

use crate::types::common::StreamingCandidateStrategy;
use crate::types::streaming::{StreamingCandidate, StreamingCandidatesResult, StreamingMetadata};

/// Port of candidates.ex:26-73.
///
/// A miss is a GraphQL error rather than a null, because the player's
/// self-heal keys on a non-empty `graphqlErrors` with a null `linkException`
/// to tell "this id is dead" apart from "the network is down"
/// (player_screen.dart:1360-1395).
pub async fn resolve_file(db: &Db, content_type: &str, id: &str) -> Result<MediaFileRow, Error> {
    let files = match content_type {
        "movie" => mydia_db::media_files::list_for_item(db, id).await,
        "episode" => mydia_db::media_files::list_for_episode(db, id).await,
        "file" => {
            return mydia_db::media_files::find(db, id)
                .await
                .map_err(|e| Error::new(e.to_string()))?
                .ok_or_else(|| Error::new("file not found"));
        }
        other => return Err(Error::new(format!("invalid content type: {other}"))),
    }
    .map_err(|e| Error::new(e.to_string()))?;

    ranking::best(&files)
        .cloned()
        .ok_or_else(|| Error::new("no media files available"))
}

pub fn candidates_for(row: &MediaFileRow) -> StreamingCandidatesResult {
    let facts = Facts {
        container: row.container.clone(),
        path: row.path.clone(),
        video_codec: row.codec.clone(),
        audio_codec: row.audio_codec.clone(),
    };

    StreamingCandidatesResult {
        file_id: ID(row.id.clone()),
        candidates: build(&facts).into_iter().map(candidate_into).collect(),
        metadata: metadata_for(row),
    }
}

fn candidate_into(candidate: Candidate) -> StreamingCandidate {
    StreamingCandidate {
        strategy: match candidate.strategy {
            Strategy::DirectPlay => StreamingCandidateStrategy::DirectPlay,
            Strategy::Remux => StreamingCandidateStrategy::Remux,
            Strategy::HlsCopy => StreamingCandidateStrategy::HlsCopy,
            Strategy::Transcode => StreamingCandidateStrategy::Transcode,
        },
        mime: candidate.mime,
        container: candidate.container,
        video_codec: candidate.video_codec,
        audio_codec: candidate.audio_codec,
    }
}

/// Port of build_metadata_response/1 (candidates.ex:133-147).
fn metadata_for(row: &MediaFileRow) -> StreamingMetadata {
    StreamingMetadata {
        duration: row.duration_seconds,
        width: row.width.and_then(|v| i32::try_from(v).ok()),
        height: row.height.and_then(|v| i32::try_from(v).ok()),
        bitrate: row.bitrate.and_then(|v| i32::try_from(v).ok()),
        resolution: row.resolution.clone(),
        hdr_format: row.hdr_format.clone(),
        original_codec: row.codec.clone(),
        original_audio_codec: row.audio_codec.clone(),
        container: row.container.clone(),
        preferred_audio_languages: None,
    }
}
