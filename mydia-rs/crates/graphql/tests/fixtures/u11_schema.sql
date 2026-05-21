CREATE TABLE users (
    id TEXT PRIMARY KEY,
    email TEXT,
    username TEXT,
    password_hash TEXT,
    role TEXT NOT NULL DEFAULT 'user',
    inserted_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE media_items (
    id TEXT PRIMARY KEY,
    type TEXT,
    title TEXT,
    original_title TEXT,
    year INTEGER,
    tmdb_id INTEGER,
    tvdb_id INTEGER,
    imdb_id TEXT,
    metadata TEXT,
    monitored INTEGER NOT NULL DEFAULT 1,
    monitoring_preset TEXT NOT NULL DEFAULT 'all',
    category TEXT,
    category_override INTEGER NOT NULL DEFAULT 0,
    seasons_refreshed_at TEXT,
    quality_profile_id TEXT,
    inserted_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE episodes (
    id TEXT PRIMARY KEY,
    media_item_id TEXT NOT NULL,
    season_number INTEGER,
    episode_number INTEGER,
    title TEXT,
    air_date TEXT,
    metadata TEXT,
    monitored INTEGER NOT NULL DEFAULT 1,
    inserted_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE media_files (
    id TEXT PRIMARY KEY,
    media_item_id TEXT,
    episode_id TEXT,
    quality_profile_id TEXT,
    library_path_id TEXT,
    path TEXT,
    relative_path TEXT,
    size INTEGER,
    resolution TEXT,
    codec TEXT,
    hdr_format TEXT,
    audio_codec TEXT,
    bitrate INTEGER,
    verified_at TEXT,
    analyzed_at TEXT,
    analysis_attempts INTEGER NOT NULL DEFAULT 0,
    last_analysis_error TEXT,
    metadata TEXT,
    cover_blob TEXT,
    sprite_blob TEXT,
    vtt_blob TEXT,
    preview_blob TEXT,
    phash TEXT,
    generated_at TEXT,
    trashed_at TEXT,
    inserted_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE playback_progress (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    media_item_id TEXT,
    episode_id TEXT,
    position_seconds INTEGER NOT NULL,
    duration_seconds INTEGER NOT NULL,
    completion_percentage REAL NOT NULL,
    watched INTEGER NOT NULL DEFAULT 0,
    last_watched_at TEXT NOT NULL,
    inserted_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE UNIQUE INDEX playback_progress_user_media_item_unique
    ON playback_progress(user_id, media_item_id)
    WHERE media_item_id IS NOT NULL;

CREATE UNIQUE INDEX playback_progress_user_episode_unique
    ON playback_progress(user_id, episode_id)
    WHERE episode_id IS NOT NULL;

CREATE TABLE collections (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    description TEXT,
    type TEXT NOT NULL DEFAULT 'manual',
    poster_path TEXT,
    sort_order TEXT NOT NULL DEFAULT 'position',
    smart_rules TEXT,
    visibility TEXT NOT NULL DEFAULT 'private',
    is_system INTEGER NOT NULL DEFAULT 0,
    position INTEGER NOT NULL DEFAULT 0,
    user_id TEXT NOT NULL,
    inserted_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE collection_items (
    id TEXT PRIMARY KEY,
    collection_id TEXT NOT NULL,
    media_item_id TEXT NOT NULL,
    position INTEGER NOT NULL DEFAULT 0,
    inserted_at TEXT NOT NULL
);

CREATE UNIQUE INDEX collection_items_unique
    ON collection_items(collection_id, media_item_id)
