defmodule Mydia.Repo.Migrations.FixEpisodeCascadeDeletesTest do
  use Mydia.MigrationCase

  Code.require_file("priv/repo/migrations/20260322000000_fix_episode_cascade_deletes.exs")

  # The migration also rebuilds downloads and playback_progress, which this
  # test does not create. Drive only the media_files half through the helper,
  # using the migration's own column and index definitions. Referenced fully
  # qualified rather than via `alias` because usage tracking does not credit
  # a reference from inside this nested module's body against an alias
  # established in the enclosing test module, which would otherwise report a
  # false-positive "unused alias" warning.
  defmodule MediaFilesOnlyMigration do
    use Ecto.Migration
    import Mydia.Repo.Migrations.Helpers

    def up do
      columns =
        Enum.map(Mydia.Repo.Migrations.FixEpisodeCascadeDeletes.__media_files_columns__(), fn
          {:episode_id, type, _opts} ->
            {:episode_id, type,
             [references: {:episodes, [type: :binary_id, on_delete: :nilify_all]}]}

          other ->
            other
        end)

      recreate_table(
        table: :media_files,
        columns: columns,
        indexes: Mydia.Repo.Migrations.FixEpisodeCascadeDeletes.__media_files_indexes__()
      )
    end
  end

  defp build_schema do
    sql!("CREATE TABLE media_items (id TEXT PRIMARY KEY)")
    sql!("CREATE TABLE episodes (id TEXT PRIMARY KEY)")
    sql!("CREATE TABLE quality_profiles (id TEXT PRIMARY KEY)")
    sql!("CREATE TABLE library_paths (id TEXT PRIMARY KEY)")
    sql!("CREATE TABLE users (id TEXT PRIMARY KEY)")

    sql!("""
    CREATE TABLE media_files (
      id TEXT PRIMARY KEY,
      media_item_id TEXT REFERENCES media_items(id) ON DELETE CASCADE,
      episode_id TEXT REFERENCES episodes(id) ON DELETE CASCADE,
      path TEXT,
      size BIGINT,
      quality_profile_id TEXT REFERENCES quality_profiles(id),
      resolution TEXT, codec TEXT, hdr_format TEXT, audio_codec TEXT,
      bitrate INTEGER, verified_at TEXT, metadata TEXT, relative_path TEXT,
      library_path_id TEXT REFERENCES library_paths(id) ON DELETE CASCADE,
      cover_blob TEXT, sprite_blob TEXT, vtt_blob TEXT, preview_blob TEXT,
      phash TEXT, generated_at TEXT, trashed_at TEXT,
      inserted_at TEXT NOT NULL, updated_at TEXT NOT NULL
    )
    """)

    sql!("""
    CREATE TABLE subtitles (id TEXT PRIMARY KEY,
      media_file_id TEXT REFERENCES media_files(id) ON DELETE CASCADE)
    """)

    sql!("""
    CREATE TABLE media_hashes (id TEXT PRIMARY KEY,
      media_file_id TEXT REFERENCES media_files(id) ON DELETE CASCADE)
    """)

    sql!("""
    CREATE TABLE transcode_jobs (id TEXT PRIMARY KEY,
      media_file_id TEXT REFERENCES media_files(id) ON DELETE CASCADE)
    """)

    sql!("INSERT INTO episodes (id) VALUES ('e1')")

    sql!("""
    INSERT INTO media_files (id, episode_id, path, inserted_at, updated_at)
    VALUES ('mf1', 'e1', '/a.mkv', '2026-01-01 00:00:00', '2026-01-01 00:00:00')
    """)

    sql!("INSERT INTO subtitles (id, media_file_id) VALUES ('s1', 'mf1')")
    sql!("INSERT INTO media_hashes (id, media_file_id) VALUES ('h1', 'mf1')")
    sql!("INSERT INTO transcode_jobs (id, media_file_id) VALUES ('t1', 'mf1')")
  end

  defp run_media_files_rebuild do
    run_migration!(MediaFilesOnlyMigration, 20_260_101_000_020)
  end

  @tag :tmp_dir
  test "rebuilding media_files keeps its subtitles" do
    build_schema()
    run_media_files_rebuild()

    assert %{rows: [["s1", "mf1"]]} = sql!("SELECT id, media_file_id FROM subtitles")
  end

  @tag :tmp_dir
  test "rebuilding media_files keeps its hashes and transcode jobs" do
    build_schema()
    run_media_files_rebuild()

    assert %{rows: [["h1", "mf1"]]} = sql!("SELECT id, media_file_id FROM media_hashes")
    assert %{rows: [["t1", "mf1"]]} = sql!("SELECT id, media_file_id FROM transcode_jobs")
  end

  @tag :tmp_dir
  test "the rebuild still changes episode_id to set null" do
    build_schema()
    run_media_files_rebuild()

    %{rows: [[sql]]} = sql!("SELECT sql FROM sqlite_master WHERE name = 'media_files'")
    assert sql =~ ~r/episode_id.*ON DELETE SET NULL/is
  end
end
