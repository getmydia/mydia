defmodule Mydia.Repo.Migrations.SplitImportCandidatesFromMediaFilesTest do
  use Mydia.MigrationCase

  Code.require_file(
    "priv/repo/migrations/20260830143721_split_import_candidates_from_media_files.exs"
  )

  alias Mydia.Repo.Migrations.SplitImportCandidatesFromMediaFiles

  @tag :tmp_dir
  test "promotes active parentless files, removes stale rows, and preserves owned files" do
    build_pre_migration_schema()

    run_migration!(SplitImportCandidatesFromMediaFiles, 20_260_830_143_721)

    assert %{rows: [["Show/Season 02/S02E03.mkv", "tvdb", "1234", 2, "[3]"]]} =
             sql!("""
             SELECT relative_path, provider_type, provider_id,
                    json_extract(parsed_info, '$.season'), json_extract(parsed_info, '$.episodes')
             FROM import_candidates
             WHERE relative_path = 'Show/Season 02/S02E03.mkv'
             """)

    assert %{rows: [["Unmatched.mkv", nil, nil]]} =
             sql!("""
             SELECT relative_path, provider_type, provider_id
             FROM import_candidates
             WHERE relative_path = 'Unmatched.mkv'
             """)

    assert %{rows: [[id]]} =
             sql!("""
             SELECT id
             FROM import_candidates
             WHERE relative_path = 'Show/Season 02/S02E03.mkv'
             """)

    assert byte_size(id) == 16
    assert {:ok, _uuid} = Ecto.UUID.load(id)

    assert %{rows: [[2]]} = sql!("SELECT count(*) FROM import_candidates")
    assert %{rows: [[2]]} = sql!("SELECT count(*) FROM media_files")

    assert %{rows: [["episode-owned"], ["movie-owned"]]} =
             sql!("SELECT id FROM media_files ORDER BY id")

    assert %{rows: [["episode-segment"], ["movie-segment"]]} =
             sql!("SELECT id FROM media_segments ORDER BY id")

    assert %{rows: [["episode-subtitle"], ["movie-subtitle"]]} =
             sql!("SELECT id FROM subtitles ORDER BY id")

    assert %{rows: [["episode-setting"], ["movie-setting"]]} =
             sql!("SELECT id FROM subtitle_track_settings ORDER BY id")

    assert %{rows: [[0]]} =
             sql!(
               "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'import_groups'"
             )

    assert %{rows: [[0]]} =
             sql!("""
             SELECT count(*) FROM sqlite_master
             WHERE type = 'table' AND name = 'media_file_match_candidates'
             """)
  end

  defp build_pre_migration_schema do
    sql!("CREATE TABLE library_paths (id TEXT PRIMARY KEY, path TEXT NOT NULL)")
    sql!("CREATE TABLE media_items (id TEXT PRIMARY KEY)")
    sql!("CREATE TABLE episodes (id TEXT PRIMARY KEY)")
    sql!("CREATE TABLE quality_profiles (id TEXT PRIMARY KEY)")
    sql!("CREATE TABLE import_groups (id TEXT PRIMARY KEY)")

    sql!("""
    CREATE TABLE media_files (
      id TEXT PRIMARY KEY,
      media_item_id TEXT REFERENCES media_items(id) ON DELETE CASCADE,
      episode_id TEXT REFERENCES episodes(id) ON DELETE SET NULL,
      quality_profile_id TEXT REFERENCES quality_profiles(id),
      library_path_id TEXT REFERENCES library_paths(id) ON DELETE CASCADE,
      import_group_id TEXT REFERENCES import_groups(id) ON DELETE SET NULL,
      path TEXT, relative_path TEXT, size BIGINT, resolution TEXT, codec TEXT,
      hdr_format TEXT, dolby_vision_profile INTEGER, dolby_vision_bl_compat_id INTEGER,
      hdr_backfilled_at TEXT, audio_codec TEXT, bitrate INTEGER, verified_at TEXT,
      analyzed_at TEXT, analysis_attempts INTEGER NOT NULL DEFAULT 0, last_analysis_error TEXT, metadata TEXT,
      cover_blob TEXT, sprite_blob TEXT, vtt_blob TEXT, preview_blob TEXT, phash TEXT,
      generated_at TEXT, trashed_at TEXT, extra_kind TEXT, extra_source TEXT,
      extra_checked_at TEXT, segment_analysis_state TEXT NOT NULL DEFAULT 'pending', segments_analyzed_at TEXT,
      segment_analysis_attempts INTEGER NOT NULL DEFAULT 0, last_segment_analysis_error TEXT,
      fingerprint_blob TEXT, supersedes_media_file_id TEXT REFERENCES media_files(id) ON DELETE SET NULL,
      inserted_at TEXT NOT NULL, updated_at TEXT NOT NULL
    )
    """)

    sql!("""
    CREATE TABLE media_file_match_candidates (
      id TEXT PRIMARY KEY, media_file_id TEXT REFERENCES media_files(id) ON DELETE CASCADE,
      rank INTEGER NOT NULL, provider_type TEXT, provider_id TEXT, title TEXT, year INTEGER,
      media_type TEXT, confidence REAL, parsed_info TEXT, attempts INTEGER, last_error TEXT,
      next_retry_at TEXT, inserted_at TEXT NOT NULL, updated_at TEXT NOT NULL
    )
    """)

    sql!("""
    CREATE TABLE media_segments (
      id TEXT PRIMARY KEY,
      media_file_id TEXT REFERENCES media_files(id) ON DELETE CASCADE
    )
    """)

    sql!("""
    CREATE TABLE subtitles (
      id TEXT PRIMARY KEY,
      media_file_id TEXT REFERENCES media_files(id) ON DELETE CASCADE
    )
    """)

    sql!("""
    CREATE TABLE subtitle_track_settings (
      id TEXT PRIMARY KEY,
      media_file_id TEXT REFERENCES media_files(id) ON DELETE CASCADE
    )
    """)

    sql!("INSERT INTO library_paths (id, path) VALUES ('library', '/media')")
    sql!("INSERT INTO media_items (id) VALUES ('movie')")
    sql!("INSERT INTO episodes (id) VALUES ('episode')")

    insert_media_file("active-match", nil, nil, nil, "Show/Season 02/S02E03.mkv")
    insert_media_file("active-unmatched", nil, nil, nil, "Unmatched.mkv")
    insert_media_file("trashed", nil, nil, "2026-08-01 00:00:00", "Trashed.mkv")
    insert_media_file("movie-owned", "movie", nil, nil, "Movie.mkv")
    insert_media_file("episode-owned", nil, "episode", nil, "Show/Season 01/S01E01.mkv")

    for {table, id, media_file_id} <- [
          {"media_segments", "orphan-segment", "active-match"},
          {"subtitles", "orphan-subtitle", "active-match"},
          {"subtitle_track_settings", "orphan-setting", "active-match"},
          {"media_segments", "movie-segment", "movie-owned"},
          {"subtitles", "movie-subtitle", "movie-owned"},
          {"subtitle_track_settings", "movie-setting", "movie-owned"},
          {"media_segments", "episode-segment", "episode-owned"},
          {"subtitles", "episode-subtitle", "episode-owned"},
          {"subtitle_track_settings", "episode-setting", "episode-owned"}
        ] do
      sql!("INSERT INTO #{table} (id, media_file_id) VALUES (?, ?)", [id, media_file_id])
    end

    sql!("""
    INSERT INTO media_file_match_candidates
      (id, media_file_id, rank, provider_type, provider_id, title, year, media_type,
       confidence, parsed_info, attempts, last_error, inserted_at, updated_at)
    VALUES
      ('rank-0', 'active-match', 0, 'tvdb', '1234', 'A Show', 2020, 'tv_show',
       0.9, '{"season":2,"episodes":[3]}', 1, NULL, '2026-08-30 14:00:00', '2026-08-30 14:00:00'),
      ('rank-1', 'active-match', 1, 'tmdb', '99', 'Wrong Result', 2020, 'tv_show',
       0.1, '{"season":2,"episodes":[3]}', 0, NULL, '2026-08-30 14:00:00', '2026-08-30 14:00:00')
    """)
  end

  defp insert_media_file(id, media_item_id, episode_id, trashed_at, relative_path) do
    sql!(
      """
      INSERT INTO media_files
        (id, media_item_id, episode_id, library_path_id, relative_path, size, trashed_at, inserted_at, updated_at)
      VALUES (?, ?, ?, 'library', ?, 100, ?, '2026-08-30 14:00:00', '2026-08-30 14:00:00')
      """,
      [id, media_item_id, episode_id, relative_path, trashed_at]
    )
  end
end
