-- Subtitle files found beside a video during the scan. Keyed on path so a
-- rescan updates rather than duplicates, and cascaded from media_files so a
-- pruned file takes its sidecars with it.
CREATE TABLE external_subtitles (
    id             TEXT PRIMARY KEY,
    media_file_id  TEXT NOT NULL REFERENCES media_files(id) ON DELETE CASCADE,
    path           TEXT NOT NULL UNIQUE,
    language       TEXT NOT NULL,
    format         TEXT NOT NULL,
    discovered_at  TEXT NOT NULL
);

CREATE INDEX external_subtitles_media_file_id ON external_subtitles(media_file_id);
