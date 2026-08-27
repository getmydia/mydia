defmodule Mydia.Repo.Migrations.SubtitlesSchemaTest do
  @moduledoc """
  `subtitles`'s NOT NULL columns and indexes must survive future migrations,
  including a SQLite table rebuild through
  `Mydia.Repo.Migrations.Helpers.recreate_table/1`.

  `recreate_table/1` only rebuilds the table on SQLite: on PostgreSQL it runs
  whatever `:postgres` statements the migration supplies and leaves the rest of
  the table untouched. A `recreate_table/1` column list that forgets a
  column's `null: false` (or drops an index from the `indexes:` list) silently
  weakens SQLite only, since the rebuild there recreates the table from that
  list alone. Nothing fails at migration time, and no existing test notices:
  `Mydia.Subtitles.Subtitle.changeset/2` already requires these fields, so
  `validate_required/2` masks the missing database constraint in every test
  that goes through the changeset rather than raw SQL.

  `20260826201450_create_subtitle_track_settings.exs` shipped exactly this bug
  once already: five NOT NULL columns and the `[:language]` index were
  silently dropped on SQLite, and the full test suite still passed. This
  asserts against the live, migrated database on whichever adapter is
  running, so a future rebuild that narrows this table fails here instead of
  shipping unnoticed.
  """
  use Mydia.DataCase, async: true

  @not_null_columns ~w(
    media_file_id language provider subtitle_hash file_path format
    hearing_impaired origin forced
  )

  @index_names ~w(
    subtitles_media_file_id_index
    subtitles_language_index
    subtitles_media_file_id_subtitle_hash_index
  )

  test "subtitles NOT NULL columns are enforced by the database" do
    missing = @not_null_columns -- not_null_columns()

    assert missing == [],
           """
           These subtitles columns should be NOT NULL but are not: #{inspect(missing)}

           If a migration rebuilt this table (SQLite, via recreate_table/1), its
           columns: list dropped null: false for one of these. Restore it there.
           """
  end

  test "subtitles carries its expected indexes" do
    missing = @index_names -- index_names()

    assert missing == [],
           """
           These subtitles indexes are missing: #{inspect(missing)}

           If a migration rebuilt this table (SQLite, via recreate_table/1), its
           indexes: list dropped one of these.
           """
  end

  defp not_null_columns do
    if Mydia.DB.postgres?() do
      %{rows: rows} =
        Repo.query!(
          """
          SELECT column_name FROM information_schema.columns
          WHERE table_schema = 'public' AND table_name = 'subtitles' AND is_nullable = 'NO'
          """,
          []
        )

      Enum.map(rows, fn [name] -> name end)
    else
      %{rows: rows} = Repo.query!(~s|PRAGMA table_info("subtitles")|, [])

      # PRAGMA table_info columns: cid, name, type, notnull, dflt_value, pk
      Enum.flat_map(rows, fn [_cid, name, _type, notnull, _default, _pk] ->
        if notnull == 1, do: [name], else: []
      end)
    end
  end

  defp index_names do
    if Mydia.DB.postgres?() do
      %{rows: rows} =
        Repo.query!("SELECT indexname FROM pg_indexes WHERE tablename = 'subtitles'", [])

      Enum.map(rows, fn [name] -> name end)
    else
      %{rows: rows} =
        Repo.query!(
          "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'subtitles'",
          []
        )

      Enum.map(rows, fn [name] -> name end)
    end
  end
end
