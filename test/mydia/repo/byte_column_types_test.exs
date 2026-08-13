defmodule Mydia.Repo.ByteColumnTypesTest do
  @moduledoc """
  Guards the class of bug behind issue #278: a byte-size column declared
  `:integer`, which PostgreSQL realises as int4 (max 2,147,483,647). Media
  files routinely exceed that, so such a column crashes every write for a large
  file, and SQLite hides it because its INTEGER storage class is 64-bit.

  This asserts against the real column types in the live schema rather than
  scanning migration files, so it also catches columns created or altered by
  raw `execute`.
  """
  use Mydia.DataCase, async: true

  alias Mydia.Repo

  # `ecto_sqlite3` maps both :integer and :bigint to the declared type INTEGER
  # (deps/ecto_sqlite3/lib/ecto/adapters/sqlite3/data_type.ex:15-16), so there
  # is nothing for this test to inspect on SQLite. CI runs PostgreSQL, so the
  # guard still gates every merge.
  @moduletag skip:
               not Mydia.DB.postgres?() and
                 "SQLite cannot distinguish :integer from :bigint; guard is PostgreSQL-only"

  # Columns whose name matches the byte-size pattern but which legitimately hold
  # a bounded count rather than a byte total. Empty today. Adding an entry here
  # is a one-line reviewable exception, which is the point: without it the only
  # remedy this test offers for a perfectly reasonable `pool_size` or
  # `batch_size` column is renaming the schema to satisfy a lint.
  @allowed []

  # '%byte%' subsumes '%bytes%'. `current_schema()` rather than a hard-coded
  # 'public' so the guard still sees the tables under a non-default search_path.
  @candidates """
  SELECT table_name, column_name, data_type
  FROM information_schema.columns
  WHERE table_schema = current_schema()
    AND (column_name LIKE '%size%' OR column_name LIKE '%byte%')
  ORDER BY table_name, column_name
  """

  test "no byte-size column is narrower than 64-bit" do
    candidates = Repo.query!(@candidates).rows

    # A schema filter that matches nothing would make the assertion below pass
    # against an empty set, and a vacuous guard is indistinguishable from a
    # working one. Fail loudly instead.
    refute candidates == [],
           "the byte-size column query matched nothing at all, so this guard is " <>
             "protecting nothing. The schema filter is probably wrong."

    offenders =
      candidates
      |> Enum.filter(fn [_table, _column, type] -> type in ["integer", "smallint"] end)
      |> Enum.reject(fn [table, column, _type] -> {table, column} in @allowed end)

    assert offenders == [], """
    These columns look like byte sizes but are narrower than 64-bit:

    #{Enum.map_join(offenders, "\n", fn [table, column, type] -> "  #{table}.#{column} is #{type}" end)}

    A byte count over 2,147,483,647 raises DBConnection.EncodeError on
    PostgreSQL and silently works on SQLite. Declare the column `:bigint` in
    its migration. For an existing column, add a migration that branches on
    `postgres?()` and issues
    `ALTER TABLE <table> ALTER COLUMN <column> TYPE bigint`; see
    priv/repo/migrations/20260813140000_widen_byte_size_columns_to_bigint.exs.

    If the column genuinely holds a bounded count rather than a byte total, add
    it to @allowed in this file with a comment saying why.
    """
  end
end
