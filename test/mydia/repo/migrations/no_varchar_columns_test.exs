defmodule Mydia.Repo.Migrations.NoVarcharColumnsTest do
  @moduledoc """
  Migration columns must be `:text`, never `:string`.

  A bare `:string` compiles to `varchar(255)` on PostgreSQL but to unconstrained
  `TEXT` affinity on SQLite. Since SQLite is the default adapter for development
  and test, a write longer than 255 characters passes locally and fails only on
  PostgreSQL with `ERROR 22001 (string_data_right_truncation)`.

  That asymmetry shipped the same bug twice: issue #286 against the library
  scanner, then again through the columns that
  `20260616120000_widen_metadata_text_columns.exs` left behind when it hand-listed
  the six that happened to be crashing.

  Two guards, because neither alone is sufficient:

    * The source check runs on every adapter, so a contributor on the default
      SQLite setup gets the failure locally instead of discovering it in the
      PostgreSQL CI job. It only reads migration text, so a column introduced by
      raw SQL slips past it.
    * The schema check cannot be fooled, since it inspects the migrated database,
      but it only carries weight where `varchar` is distinguishable from `text`.

  Length limits the application actually intends belong in changesets via
  `validate_length/3`, where they are visible and adapter-independent.
  """
  use Mydia.DataCase, async: true

  # Migrations up to and including the sweep that widened the existing columns
  # (20260813140000) are grandfathered: their `varchar` columns were converted in
  # the database rather than by rewriting migration history. Anything newer is
  # held to the rule. A timestamp cutoff rather than a file allowlist, so this
  # cannot drift as migrations are added.
  @cutoff "20260813140000"

  @column_decl ~r/^\s*(?:add|add_if_not_exists|modify)\s+:(\w+),\s*:string\b/m

  describe "migration source" do
    test "no migration newer than the varchar sweep declares a :string column" do
      offenders =
        "priv/repo/migrations/*.exs"
        |> Path.wildcard()
        |> Enum.filter(&newer_than_cutoff?/1)
        |> Enum.flat_map(&string_columns/1)
        |> Enum.sort()

      assert offenders == [],
             """
             These migrations declare `:string` columns:

               #{Enum.join(offenders, "\n  ")}

             `:string` becomes varchar(255) on PostgreSQL but unconstrained TEXT on
             SQLite, so an over-long write passes in development and fails in
             production with ERROR 22001 (string_data_right_truncation).

             Use `:text` instead. The Ecto schema still declares
             `field :name, :string` either way; only the migration type changes.
             To bound a value, add `validate_length/3` to the changeset.
             """
    end

    test "the cutoff still names a real migration" do
      matching =
        "priv/repo/migrations/#{@cutoff}_*.exs"
        |> Path.wildcard()

      assert matching != [],
             "cutoff #{@cutoff} names no migration; update @cutoff if it was renamed"
    end
  end

  # On SQLite `:string` and `:text` are both stored as unconstrained TEXT affinity,
  # so there is no length limit to observe and nothing to assert.
  if Mydia.Repo.__adapter__() == Ecto.Adapters.Postgres do
    describe "migrated schema" do
      @query """
      SELECT c.table_name, c.column_name, c.character_maximum_length
      FROM information_schema.columns c
      JOIN information_schema.tables t
        ON t.table_schema = c.table_schema
       AND t.table_name = c.table_name
      WHERE c.table_schema = 'public'
        AND c.data_type = 'character varying'
        AND t.table_type = 'BASE TABLE'
        AND c.table_name <> 'schema_migrations'
        AND c.table_name NOT LIKE 'oban_%'
      ORDER BY c.table_name, c.column_name
      """

      test "no table declares a length-limited varchar column" do
        %{rows: rows} = Repo.query!(@query, [])

        assert rows == [],
               """
               These columns are varchar rather than TEXT:

                 #{Enum.map_join(rows, "\n  ", fn [table, column, len] -> "#{table}.#{column} varchar(#{len})" end)}

               Writes longer than the limit fail on PostgreSQL with ERROR 22001
               (string_data_right_truncation) while passing on SQLite.

               Use `:text` in the migration that adds the column.
               """
      end
    end
  end

  defp newer_than_cutoff?(path) do
    path |> Path.basename() |> String.slice(0, String.length(@cutoff)) > @cutoff
  end

  defp string_columns(path) do
    @column_decl
    |> Regex.scan(File.read!(path), capture: :all_but_first)
    |> Enum.map(fn [column] -> "#{Path.basename(path)}: #{column}" end)
  end
end
