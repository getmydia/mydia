CREATE TABLE users (
    id TEXT PRIMARY KEY,
    username TEXT,
    email TEXT,
    password_hash TEXT,
    oidc_sub TEXT,
    oidc_issuer TEXT,
    role TEXT NOT NULL DEFAULT 'user',
    display_name TEXT,
    avatar_url TEXT,
    last_login_at TEXT,
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

CREATE TABLE api_keys (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    name TEXT,
    key_hash TEXT,
    key_prefix TEXT,
    permissions TEXT,
    last_used_at TEXT,
    expires_at TEXT,
    revoked_at TEXT,
    inserted_at TEXT NOT NULL
);

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
)
