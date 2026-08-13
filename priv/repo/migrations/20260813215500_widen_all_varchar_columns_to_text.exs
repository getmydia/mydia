defmodule Mydia.Repo.Migrations.WidenAllVarcharColumnsToText do
  use Ecto.Migration
  import Mydia.Repo.Migrations.Helpers

  @moduledoc """
  Widen every remaining `VARCHAR(255)` column to `TEXT` on PostgreSQL.

  In Ecto a bare `:string` column compiles to `varchar(255)` on PostgreSQL but to
  unconstrained `TEXT` affinity on SQLite. Since SQLite is the default adapter for
  development, test, and most self-hosted deployments, a write longer than 255
  characters succeeds locally and fails only on PostgreSQL with `ERROR 22001
  (string_data_right_truncation)`.

  `20260616120000_widen_metadata_text_columns.exs` fixed the six columns that were
  actively crashing library scans. It hand-listed them, which is why it left the
  rest of the class in place: `subtitles.file_path` (derived from the media path
  plus a language suffix, so strictly longer than the `media_files.path` that
  forced the original fix), `import_sessions.scan_path`,
  `transcode_jobs.output_path`, `library_paths.path`, and the unbounded provider
  error strings in `import_lists.sync_error` and `plex_*.last_auth_error`.

  This migration introspects `information_schema` rather than enumerating columns,
  so it covers every table regardless of migration history.
  `test/mydia/repo/migrations/no_varchar_columns_test.exs` then holds the line for
  future migrations.

  `{:array, :string}` is included. It compiles to `varchar(255)[]`, which reports
  `data_type = 'ARRAY'` rather than `'character varying'` and so is invisible to
  the obvious query. `custom_formats.patterns` is exactly this: a
  `varchar(255)[]` whose changeset explicitly permits 500-character patterns
  (`Mydia.Settings.CustomFormat`), so on PostgreSQL a valid save could fail.

  Widening is safe rather than merely tolerable: the schema declares 245 `:string`
  columns and never once passes `size:`, so no `varchar` length here was chosen
  deliberately. Length rules the application actually intends live in changesets
  via `validate_length/3`.

  Oban and ErrorTracker are excluded. Both own their schemas and ship their own
  migrations, so rewriting their column types would be reaching into another
  library's tables, and the companion test excludes them for the same reason: a
  dep bump that adds a varchar column must not fail a guard that has no mydia
  source to fix.

  On SQLite this is a no-op: `:string` and `:text` are both stored as unconstrained
  `TEXT` affinity, so the declared length is already ignored and no table rebuild
  is required.

  Cost on PostgreSQL is low. `varchar(n)` -> `text` is binary-coercible, so the
  server skips the table rewrite and, absent a collation change, leaves dependent
  indexes intact; the change is metadata-only under a brief `ACCESS EXCLUSIVE`
  lock taken before the endpoint accepts traffic. `20260616120000` already
  demonstrated this against `media_files.path`, which carries a UNIQUE btree index.
  """

  def up do
    if postgres?() do
      for {table, column, type} <- varchar_columns() do
        execute(~s(ALTER TABLE "#{table}" ALTER COLUMN "#{column}" TYPE #{type}))
      end
    end
  end

  # Deliberately irreversible in the narrowing direction. Once a value longer than
  # 255 characters is stored, `TEXT` -> `VARCHAR(255)` hard-fails, and a self-hosted
  # operator rolling back a release must never hit a migration that refuses to run.
  # A wider column never breaks older code, so leaving the schema wide is the safe
  # direction.
  def down do
    :ok
  end

  defp varchar_columns do
    %{rows: rows} =
      repo().query!(
        """
        SELECT c.table_name, c.column_name, c.data_type
        FROM information_schema.columns c
        JOIN information_schema.tables t
          ON t.table_schema = c.table_schema
         AND t.table_name = c.table_name
        WHERE c.table_schema = 'public'
          AND (c.data_type = 'character varying'
               OR (c.data_type = 'ARRAY' AND c.udt_name = '_varchar'))
          AND t.table_type = 'BASE TABLE'
          AND c.table_name <> 'schema_migrations'
          AND c.table_name NOT LIKE 'oban\\_%'
          AND c.table_name NOT LIKE 'error\\_tracker\\_%'
        ORDER BY c.table_name, c.column_name
        """,
        []
      )

    Enum.map(rows, fn
      [table, column, "ARRAY"] -> {table, column, "TEXT[]"}
      [table, column, _] -> {table, column, "TEXT"}
    end)
  end
end
