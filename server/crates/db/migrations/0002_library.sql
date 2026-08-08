-- Library paths the operator pointed us at. Mydia Server reads these
-- directories and never writes inside them, so there are no organize, rename
-- or import columns here: those capabilities are absent from the product,
-- not disabled by a flag.
CREATE TABLE library_paths (
    id            TEXT PRIMARY KEY NOT NULL,
    path          TEXT NOT NULL UNIQUE,
    library_type  TEXT NOT NULL CHECK (library_type IN ('movies', 'series', 'mixed')),
    monitored     INTEGER NOT NULL DEFAULT 1,
    scan_interval INTEGER,
    last_scan_at  TEXT,
    inserted_at   TEXT NOT NULL,
    updated_at    TEXT NOT NULL
);

-- One row per movie or per show. Episodes hang off a show; movie files hang
-- off the item directly.
CREATE TABLE media_items (
    id              TEXT PRIMARY KEY NOT NULL,
    library_path_id TEXT NOT NULL REFERENCES library_paths(id) ON DELETE CASCADE,
    media_type      TEXT NOT NULL CHECK (media_type IN ('movie', 'tv_show')),
    title           TEXT NOT NULL,
    -- Lowercased, punctuation-free form of the title. Identity for grouping
    -- across rescans; never displayed.
    identity_key    TEXT NOT NULL,
    original_title  TEXT,
    year            INTEGER,
    tmdb_id         INTEGER,
    tvdb_id         INTEGER,
    imdb_id         TEXT,
    overview        TEXT,
    runtime         INTEGER,
    content_rating  TEXT,
    rating          REAL,
    status          TEXT,
    -- JSON array of strings. Populated by Slice 2b.
    genres          TEXT,
    poster_url      TEXT,
    backdrop_url    TEXT,
    thumbnail_url   TEXT,
    metadata_source TEXT,
    added_at        TEXT NOT NULL,
    updated_at      TEXT NOT NULL
);

-- SQLite treats NULLs as distinct in a UNIQUE index, so a missing year folds
-- to a sentinel. Without this, a rescan would insert a second row for every
-- item whose filename carries no year.
CREATE UNIQUE INDEX media_items_identity_idx
    ON media_items (library_path_id, media_type, identity_key, COALESCE(year, -1));

CREATE INDEX media_items_type_title_idx ON media_items (media_type, title);

CREATE TABLE episodes (
    id             TEXT PRIMARY KEY NOT NULL,
    show_id        TEXT NOT NULL REFERENCES media_items(id) ON DELETE CASCADE,
    season_number  INTEGER NOT NULL,
    episode_number INTEGER NOT NULL,
    title          TEXT,
    overview       TEXT,
    air_date       TEXT,
    runtime        INTEGER,
    thumbnail_url  TEXT,
    added_at       TEXT NOT NULL,
    updated_at     TEXT NOT NULL,
    UNIQUE (show_id, season_number, episode_number)
);

CREATE INDEX episodes_show_season_idx ON episodes (show_id, season_number, episode_number);

-- A file belongs to a movie or to an episode, never both and never neither.
CREATE TABLE media_files (
    id               TEXT PRIMARY KEY NOT NULL,
    media_item_id    TEXT REFERENCES media_items(id) ON DELETE CASCADE,
    episode_id       TEXT REFERENCES episodes(id) ON DELETE CASCADE,
    path             TEXT NOT NULL UNIQUE,
    size             INTEGER,
    resolution       TEXT,
    codec            TEXT,
    audio_codec      TEXT,
    hdr_format       TEXT,
    bitrate          INTEGER,
    duration_seconds REAL,
    container        TEXT,
    width            INTEGER,
    height           INTEGER,
    -- JSON array of embedded subtitle tracks, straight off ffprobe.
    subtitle_tracks  TEXT,
    mtime            TEXT NOT NULL,
    scanned_at       TEXT NOT NULL,
    CHECK ((media_item_id IS NOT NULL) <> (episode_id IS NOT NULL))
);

CREATE INDEX media_files_media_item_idx ON media_files (media_item_id);
CREATE INDEX media_files_episode_idx ON media_files (episode_id);

-- Durable per-run state. The API and, from Slice 7, the admin UI read these
-- tables rather than any queue, so progress survives a restart.
CREATE TABLE scan_runs (
    id              TEXT PRIMARY KEY NOT NULL,
    library_path_id TEXT NOT NULL REFERENCES library_paths(id) ON DELETE CASCADE,
    state           TEXT NOT NULL CHECK (state IN ('running', 'completed', 'failed')),
    files_seen      INTEGER NOT NULL DEFAULT 0,
    files_indexed   INTEGER NOT NULL DEFAULT 0,
    files_failed    INTEGER NOT NULL DEFAULT 0,
    started_at      TEXT NOT NULL,
    finished_at     TEXT,
    error           TEXT
);

CREATE INDEX scan_runs_path_started_idx ON scan_runs (library_path_id, started_at DESC);

-- One row per file the scan could not index. A scan never aborts on one bad
-- file, so this is where the operator finds out what was skipped and why.
CREATE TABLE scan_issues (
    id          TEXT PRIMARY KEY NOT NULL,
    scan_run_id TEXT NOT NULL REFERENCES scan_runs(id) ON DELETE CASCADE,
    path        TEXT NOT NULL,
    reason      TEXT NOT NULL,
    detail      TEXT,
    occurred_at TEXT NOT NULL
);

CREATE INDEX scan_issues_run_idx ON scan_issues (scan_run_id);
