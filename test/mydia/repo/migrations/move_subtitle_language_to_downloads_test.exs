defmodule Mydia.Repo.Migrations.MoveSubtitleLanguageToDownloadsTest do
  use Mydia.MigrationCase

  Code.require_file("priv/repo/migrations/20260920043401_move_subtitle_language_to_downloads.exs")

  alias Mydia.Repo.Migrations.MoveSubtitleLanguageToDownloads

  @version 20_260_920_043_401

  defp build_schema do
    sql!("""
    CREATE TABLE config_settings (
      id TEXT PRIMARY KEY NOT NULL,
      key TEXT NOT NULL,
      value TEXT,
      category TEXT NOT NULL,
      description TEXT,
      updated_by_id TEXT,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """)

    sql!("CREATE UNIQUE INDEX config_settings_key_index ON config_settings (key)")
  end

  defp insert_setting(id, key, value, category) do
    sql!(
      """
      INSERT INTO config_settings (id, key, value, category, inserted_at, updated_at)
      VALUES (?, ?, ?, ?, '2026-01-01 00:00:00', '2026-01-01 00:00:00')
      """,
      [id, key, value, category]
    )
  end

  defp setting_rows,
    do: sql!("SELECT key, value, category FROM config_settings ORDER BY key").rows

  @tag :tmp_dir
  test "moves an acquisition value to the downloads key" do
    build_schema()
    insert_setting("s1", "streaming.subtitle_language", "en,fr", "streaming")

    run_migration!(MoveSubtitleLanguageToDownloads, @version)

    assert setting_rows() == [["downloads.subtitle_language", "en,fr", "downloads"]]
  end

  @tag :tmp_dir
  test "drops the source row when the destination already exists" do
    build_schema()
    insert_setting("s1", "streaming.subtitle_language", "en", "streaming")
    insert_setting("s2", "downloads.subtitle_language", "fr", "downloads")

    run_migration!(MoveSubtitleLanguageToDownloads, @version)

    assert setting_rows() == [["downloads.subtitle_language", "fr", "downloads"]]
  end

  @tag :tmp_dir
  test "rolls back after a playback value was written under the freed key" do
    # This is the failure. `up/0` frees streaming.subtitle_language for its new
    # meaning, so an operator can write a playback value there. `down/0` then
    # renamed the downloads row onto that same key and hit the unique index.
    build_schema()
    insert_setting("s1", "streaming.subtitle_language", "en", "streaming")

    run_migration!(MoveSubtitleLanguageToDownloads, @version)
    insert_setting("s2", "streaming.subtitle_language", "fr", "streaming")

    rollback_migration!(MoveSubtitleLanguageToDownloads, @version)

    # The acquisition value is restored. The playback value is dropped: that
    # key does not mean "which subtitle plays" in the world this rolls back to.
    assert setting_rows() == [["streaming.subtitle_language", "en", "streaming"]]
  end

  @tag :tmp_dir
  test "rolls back cleanly when no playback value was written" do
    build_schema()
    insert_setting("s1", "streaming.subtitle_language", "en", "streaming")

    run_migration!(MoveSubtitleLanguageToDownloads, @version)
    rollback_migration!(MoveSubtitleLanguageToDownloads, @version)

    assert setting_rows() == [["streaming.subtitle_language", "en", "streaming"]]
  end
end
