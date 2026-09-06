defmodule Mydia.Repo.Migrations.ScopeProviderIdUniquenessByTypeTest do
  @moduledoc """
  `up` is a pure relaxation: a composite unique index on `(type, tmdb_id)` is
  strictly weaker than a global one on `tmdb_id`, so no existing row can fail
  it and there is no data step to test. What is worth testing is that the
  relaxation is real, that it stops exactly where it should, and that `down`
  refuses rather than half-applying when the library has taken advantage of it.
  """
  use Mydia.MigrationCase

  Code.require_file(
    "priv/repo/migrations/20260905143012_scope_provider_id_uniqueness_by_type.exs"
  )

  alias Mydia.Repo.Migrations.ScopeProviderIdUniquenessByType

  @version 20_260_905_143_012

  @tag :tmp_dir
  test "a movie and a tv show may share a tmdb_id after the migration" do
    seed_schema()
    run_migration!(ScopeProviderIdUniquenessByType, @version)

    insert_item("a", "movie", "Cinder Lantern", tmdb_id: 4001)
    insert_item("b", "tv_show", "Cinder Lantern", tmdb_id: 4001)

    assert %{rows: [[2]]} = sql!("SELECT COUNT(*) FROM media_items WHERE tmdb_id = 4001")
  end

  @tag :tmp_dir
  test "a movie and a tv show may share a tvdb_id after the migration" do
    seed_schema()
    run_migration!(ScopeProviderIdUniquenessByType, @version)

    insert_item("a", "movie", "Harrow Bay", tvdb_id: 4002)
    insert_item("b", "tv_show", "Harrow Bay", tvdb_id: 4002)

    assert %{rows: [[2]]} = sql!("SELECT COUNT(*) FROM media_items WHERE tvdb_id = 4002")
  end

  @tag :tmp_dir
  test "two rows of the same type still may not share a tmdb_id" do
    seed_schema()
    run_migration!(ScopeProviderIdUniquenessByType, @version)

    insert_item("a", "tv_show", "Pale Orchard", tmdb_id: 4003)

    assert_raise Exqlite.Error, fn ->
      insert_item("b", "tv_show", "Pale Orchard Redux", tmdb_id: 4003)
    end
  end

  @tag :tmp_dir
  test "down refuses, naming the ids, when a provider id is held across two types" do
    seed_schema()
    run_migration!(ScopeProviderIdUniquenessByType, @version)

    insert_item("a", "movie", "Vellum Coast", tmdb_id: 4004)
    insert_item("b", "tv_show", "Vellum Coast", tmdb_id: 4004)

    error =
      assert_raise Ecto.MigrationError, fn ->
        rollback_migration!(ScopeProviderIdUniquenessByType, @version)
      end

    assert error.message =~ "4004"
    assert error.message =~ "Vellum Coast"

    # The guard runs before any DDL, so both rows and the composite index survive.
    assert %{rows: [[2]]} = sql!("SELECT COUNT(*) FROM media_items WHERE tmdb_id = 4004")
  end

  @tag :tmp_dir
  test "down restores the global index when no provider id spans two types" do
    seed_schema()
    run_migration!(ScopeProviderIdUniquenessByType, @version)

    insert_item("a", "movie", "Cinder Lantern", tmdb_id: 4005)

    rollback_migration!(ScopeProviderIdUniquenessByType, @version)

    assert_raise Exqlite.Error, fn ->
      insert_item("b", "tv_show", "Cinder Lantern", tmdb_id: 4005)
    end
  end

  @tag :tmp_dir
  test "up succeeds on an install whose media_items predates the named tmdb index" do
    seed_legacy_schema()

    run_migration!(ScopeProviderIdUniquenessByType, @version)

    assert index?("media_items_type_tmdb_id_index")
    assert index?("media_items_type_tvdb_id_index")
    refute index?("media_items_tvdb_id_index")
  end

  @tag :tmp_dir
  test "the legacy inline UNIQUE still scopes tmdb_id globally after the migration" do
    seed_legacy_schema()
    run_migration!(ScopeProviderIdUniquenessByType, @version)

    insert_item("a", "movie", "Cinder Lantern", tmdb_id: 4006)

    # Not the behaviour this migration wants, but the honest state of a
    # pre-2025-11-24 database: `tmdb_id INTEGER UNIQUE` is a column constraint
    # and only a table rebuild can remove it. Flipping this to an `assert` is
    # the test that a rebuild actually landed.
    assert_raise Exqlite.Error, fn ->
      insert_item("b", "tv_show", "Cinder Lantern", tmdb_id: 4006)
    end

    # The tvdb relaxation is unaffected: that index was always a named one.
    insert_item("c", "movie", "Harrow Bay", tvdb_id: 4007)
    insert_item("d", "tv_show", "Harrow Bay", tvdb_id: 4007)
    assert %{rows: [[2]]} = sql!("SELECT COUNT(*) FROM media_items WHERE tvdb_id = 4007")
  end

  # Only the columns and indexes this migration touches. The real table has far
  # more, none of which the migration reads.
  defp seed_schema do
    sql!("""
    CREATE TABLE media_items (
      id TEXT PRIMARY KEY,
      type TEXT NOT NULL,
      title TEXT NOT NULL,
      tmdb_id INTEGER,
      tvdb_id INTEGER,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """)

    sql!("CREATE UNIQUE INDEX media_items_tmdb_id_index ON media_items (tmdb_id)")

    sql!(
      "CREATE UNIQUE INDEX media_items_tvdb_id_index ON media_items (tvdb_id) WHERE tvdb_id IS NOT NULL"
    )
  end

  # The shape an install created before 2025-11-24 still has: `media_items` came
  # from a raw `CREATE TABLE` with `tmdb_id INTEGER UNIQUE` inline, so SQLite
  # enforces it through an autoindex and `media_items_tmdb_id_index` does not
  # exist. `tvdb_id` arrived later, through a normal migration, so its named
  # index does.
  defp seed_legacy_schema do
    sql!("""
    CREATE TABLE media_items (
      id TEXT PRIMARY KEY NOT NULL,
      type TEXT NOT NULL CHECK(type IN ('movie', 'tv_show')),
      title TEXT NOT NULL,
      original_title TEXT,
      year INTEGER,
      tmdb_id INTEGER UNIQUE,
      imdb_id TEXT,
      metadata TEXT,
      monitored INTEGER DEFAULT 1 CHECK(monitored IN (0, 1)),
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """)

    sql!("ALTER TABLE media_items ADD COLUMN tvdb_id INTEGER")

    sql!(
      "CREATE UNIQUE INDEX media_items_tvdb_id_index ON media_items (tvdb_id) WHERE tvdb_id IS NOT NULL"
    )

    refute index?("media_items_tmdb_id_index")
  end

  defp index?(name) do
    %{rows: [[count]]} =
      sql!("SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = ?1", [name])

    count == 1
  end

  defp insert_item(id, type, title, ids) do
    sql!(
      """
      INSERT INTO media_items (id, type, title, tmdb_id, tvdb_id, inserted_at, updated_at)
      VALUES (?1, ?2, ?3, ?4, ?5, '2026-09-05 00:00:00', '2026-09-05 00:00:00')
      """,
      [id, type, title, ids[:tmdb_id], ids[:tvdb_id]]
    )
  end
end
