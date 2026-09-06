defmodule Mydia.Repo.Migrations.DropLegacyMediaItemsTmdbInlineUniqueTest do
  @moduledoc """
  The migration rebuilds `media_items` to shed a `UNIQUE` that only exists on
  databases created before 2025-11-24, so the tests that matter are the ones a
  rebuild can get wrong: does the constraint actually go, does everything else
  about the table survive, and do the tables referencing it keep their rows.
  """
  use Mydia.MigrationCase

  Code.require_file(
    "priv/repo/migrations/20260906003007_drop_legacy_media_items_tmdb_inline_unique.exs"
  )

  alias Mydia.Repo.Migrations.DropLegacyMediaItemsTmdbInlineUnique

  @version 20_260_906_003_007

  @tag :tmp_dir
  test "a movie and a tv show may share a tmdb_id once the inline UNIQUE is gone" do
    seed_legacy_schema()

    # The state 20260905143012 leaves behind on these installs: composite index
    # present, inline constraint still enforcing global uniqueness.
    insert_item("a", "movie", "Cinder Lantern", tmdb_id: 5001)

    assert_raise Exqlite.Error, fn ->
      insert_item("b", "tv_show", "Cinder Lantern", tmdb_id: 5001)
    end

    sql!("DELETE FROM media_items")
    run_migration!(DropLegacyMediaItemsTmdbInlineUnique, @version)

    insert_item("a", "movie", "Cinder Lantern", tmdb_id: 5001)
    insert_item("b", "tv_show", "Cinder Lantern", tmdb_id: 5001)

    assert %{rows: [[2]]} = sql!("SELECT COUNT(*) FROM media_items WHERE tmdb_id = 5001")
  end

  @tag :tmp_dir
  test "two rows of the same type still may not share a tmdb_id" do
    seed_legacy_schema()
    run_migration!(DropLegacyMediaItemsTmdbInlineUnique, @version)

    insert_item("a", "tv_show", "Pale Orchard", tmdb_id: 5002)

    assert_raise Exqlite.Error, fn ->
      insert_item("b", "tv_show", "Pale Orchard Redux", tmdb_id: 5002)
    end
  end

  @tag :tmp_dir
  test "the rebuild preserves every column, with its type, nullability and default" do
    seed_legacy_schema()
    before = table_info()

    run_migration!(DropLegacyMediaItemsTmdbInlineUnique, @version)
    rebuilt = table_info()

    # Column order changes: recreate_table/1 appends the timestamps rather than
    # leaving them where the raw DDL put them. The set may not.
    assert Map.keys(rebuilt) == Map.keys(before)

    # `monitored` is the one column allowed to differ, and only in how its
    # default is spelled. SQLite has treated `true` as an alias for 1 since
    # 3.23, and `DEFAULT true` is what every post-conversion install already
    # has, so the rebuild converges the two rather than changing behaviour.
    assert before["monitored"] == {"INTEGER", 0, "1", 0}
    assert rebuilt["monitored"] == {"INTEGER", 0, "true", 0}

    for {column, spec} <- Map.drop(before, ["monitored"]) do
      assert rebuilt[column] == spec, "#{column} changed shape across the rebuild"
    end

    # Called out because Ecto's `primary_key: true` alone does not emit it, and
    # SQLite admits a NULL into a TEXT PRIMARY KEY that lacks it.
    assert {"TEXT", 1, nil, 1} = rebuilt["id"]
  end

  @tag :tmp_dir
  test "the rebuild preserves both foreign keys and their delete actions" do
    seed_legacy_schema()

    run_migration!(DropLegacyMediaItemsTmdbInlineUnique, @version)

    assert foreign_keys() == [
             {"library_paths", "library_path_id", "id", "SET NULL"},
             {"quality_profiles", "quality_profile_id", "id", "SET NULL"}
           ]
  end

  @tag :tmp_dir
  test "a nilify_all parent delete still nulls the column rather than cascading" do
    seed_legacy_schema()

    sql!("INSERT INTO quality_profiles (id, name) VALUES ('q1', 'Standard')")
    insert_item("a", "movie", "Vellum Coast", tmdb_id: 5005)
    sql!("UPDATE media_items SET quality_profile_id = 'q1' WHERE id = 'a'")

    run_migration!(DropLegacyMediaItemsTmdbInlineUnique, @version)

    sql!("DELETE FROM quality_profiles WHERE id = 'q1'")

    assert %{rows: [["a", nil]]} = sql!("SELECT id, quality_profile_id FROM media_items")
  end

  @tag :tmp_dir
  test "the rebuild preserves every index" do
    seed_legacy_schema()

    run_migration!(DropLegacyMediaItemsTmdbInlineUnique, @version)

    assert named_indexes() == [
             "media_items_category_index",
             "media_items_imdb_id_index",
             "media_items_last_upgrade_check_at_index",
             "media_items_library_path_id_index",
             "media_items_quality_profile_id_index",
             "media_items_title_index",
             "media_items_type_index",
             "media_items_type_tmdb_id_index",
             "media_items_type_tvdb_id_index"
           ]

    refute Enum.any?(index_origins(), &(&1 == "u")),
           "a UNIQUE declared in CREATE TABLE survived the rebuild"
  end

  @tag :tmp_dir
  test "children of media_items keep their rows through the rebuild" do
    seed_legacy_schema()
    insert_item("a", "tv_show", "Harrow Bay", tmdb_id: 5003)

    sql!("""
    INSERT INTO episodes (id, media_item_id, season_number, episode_number, inserted_at, updated_at)
    VALUES ('e1', 'a', 1, 1, '2026-09-06 00:00:00', '2026-09-06 00:00:00')
    """)

    sql!("""
    INSERT INTO media_files (id, episode_id, relative_path, inserted_at, updated_at)
    VALUES ('mf1', 'e1', 'Harrow Bay/S01E01.mkv', '2026-09-06 00:00:00', '2026-09-06 00:00:00')
    """)

    sql!("""
    INSERT INTO user_favorites (id, media_item_id, inserted_at, updated_at)
    VALUES ('f1', 'a', '2026-09-06 00:00:00', '2026-09-06 00:00:00')
    """)

    run_migration!(DropLegacyMediaItemsTmdbInlineUnique, @version)

    # `media_files` is the one that matters: it is two levels down, so it only
    # survives if the snapshot recursed rather than stopping at direct children.
    assert %{rows: [["e1", "a"]]} = sql!("SELECT id, media_item_id FROM episodes")
    assert %{rows: [["mf1", "e1"]]} = sql!("SELECT id, episode_id FROM media_files")
    assert %{rows: [["f1", "a"]]} = sql!("SELECT id, media_item_id FROM user_favorites")
    assert %{rows: [["a"]]} = sql!("SELECT id FROM media_items")
  end

  @tag :tmp_dir
  test "it is a no-op on a database whose media_items never had the inline UNIQUE" do
    seed_modern_schema()

    run_migration!(DropLegacyMediaItemsTmdbInlineUnique, @version)

    # Rebuilding would have renamed the backing table and reordered the columns;
    # the guard means nothing ran at all.
    assert %{rows: [[sql]]} =
             sql!("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'media_items'")

    assert sql =~ "modern_marker"
  end

  @tag :tmp_dir
  test "running it twice is harmless" do
    seed_legacy_schema()
    run_migration!(DropLegacyMediaItemsTmdbInlineUnique, @version)

    after_first = table_info()
    rollback_migration!(DropLegacyMediaItemsTmdbInlineUnique, @version)
    run_migration!(DropLegacyMediaItemsTmdbInlineUnique, @version)

    assert table_info() == after_first
    insert_item("a", "movie", "Vellum Coast", tmdb_id: 5004)
    insert_item("b", "tv_show", "Vellum Coast", tmdb_id: 5004)
  end

  # The `media_items` an install created before 2025-11-24 still has: the raw
  # `CREATE TABLE` from the original body of 20251104023000, every column later
  # migrations added, and the index set 20260905143012 leaves behind.
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

    for statement <- [
          ~s|ALTER TABLE media_items ADD COLUMN "quality_profile_id" TEXT CONSTRAINT "media_items_quality_profile_id_fkey" REFERENCES "quality_profiles"("id") ON DELETE SET NULL|,
          ~s|ALTER TABLE media_items ADD COLUMN "category" TEXT|,
          ~s|ALTER TABLE media_items ADD COLUMN "category_override" INTEGER DEFAULT false NOT NULL|,
          ~s|ALTER TABLE media_items ADD COLUMN "seasons_refreshed_at" TEXT|,
          ~s|ALTER TABLE media_items ADD COLUMN "tvdb_id" INTEGER|,
          ~s|ALTER TABLE media_items ADD COLUMN "metadata_source" TEXT|,
          ~s|ALTER TABLE media_items ADD COLUMN "last_upgrade_check_at" TEXT|,
          ~s|ALTER TABLE media_items ADD COLUMN "library_path_id" TEXT CONSTRAINT "media_items_library_path_id_fkey" REFERENCES "library_paths"("id") ON DELETE SET NULL|,
          ~s|ALTER TABLE media_items ADD COLUMN "monitor_new_seasons" TEXT DEFAULT 'all'|,
          ~s|ALTER TABLE media_items ADD COLUMN "season_order" TEXT|
        ] do
      sql!(statement)
    end

    seed_referenced_tables()
    seed_child_tables()
    seed_post_143012_indexes()
  end

  # Only enough of a modern `media_items` to prove the guard skips it. The
  # marker column is what a rebuild would silently drop.
  defp seed_modern_schema do
    sql!("""
    CREATE TABLE media_items (
      id TEXT PRIMARY KEY,
      type TEXT NOT NULL,
      title TEXT NOT NULL,
      tmdb_id INTEGER,
      tvdb_id INTEGER,
      modern_marker TEXT,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """)

    sql!("CREATE UNIQUE INDEX media_items_tmdb_id_index ON media_items (tmdb_id)")
  end

  # `quality_profiles` and `library_paths` are the two tables media_items points
  # at. They have to exist for the rebuilt table's foreign keys to resolve.
  defp seed_referenced_tables do
    sql!(~s|CREATE TABLE quality_profiles (id TEXT PRIMARY KEY, name TEXT NOT NULL)|)
    sql!(~s|CREATE TABLE library_paths (id TEXT PRIMARY KEY, path TEXT NOT NULL)|)
  end

  # One `ON DELETE CASCADE` child of each kind the rebuild has to protect: one
  # that is itself a parent, so the snapshot has to recurse (`episodes`, which
  # `media_files` hangs off), and one that is a leaf.
  defp seed_child_tables do
    sql!("""
    CREATE TABLE episodes (
      id TEXT PRIMARY KEY NOT NULL,
      media_item_id TEXT NOT NULL REFERENCES media_items(id) ON DELETE CASCADE,
      season_number INTEGER NOT NULL,
      episode_number INTEGER NOT NULL,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """)

    sql!("""
    CREATE TABLE media_files (
      id TEXT PRIMARY KEY,
      episode_id TEXT REFERENCES episodes(id) ON DELETE CASCADE,
      relative_path TEXT,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """)

    sql!("""
    CREATE TABLE user_favorites (
      id TEXT PRIMARY KEY,
      media_item_id TEXT NOT NULL REFERENCES media_items(id) ON DELETE CASCADE,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """)
  end

  defp seed_post_143012_indexes do
    for statement <- [
          ~s|CREATE INDEX "media_items_imdb_id_index" ON "media_items" ("imdb_id")|,
          ~s|CREATE INDEX "media_items_title_index" ON "media_items" ("title")|,
          ~s|CREATE INDEX "media_items_type_index" ON "media_items" ("type")|,
          ~s|CREATE INDEX "media_items_quality_profile_id_index" ON "media_items" ("quality_profile_id")|,
          ~s|CREATE INDEX "media_items_category_index" ON "media_items" ("category")|,
          ~s|CREATE INDEX "media_items_last_upgrade_check_at_index" ON "media_items" ("last_upgrade_check_at")|,
          ~s|CREATE INDEX "media_items_library_path_id_index" ON "media_items" ("library_path_id")|,
          ~s|CREATE UNIQUE INDEX "media_items_type_tmdb_id_index" ON "media_items" ("type", "tmdb_id") WHERE tmdb_id IS NOT NULL|,
          ~s|CREATE UNIQUE INDEX "media_items_type_tvdb_id_index" ON "media_items" ("type", "tvdb_id") WHERE tvdb_id IS NOT NULL|
        ] do
      sql!(statement)
    end
  end

  # name => {type, notnull, default, primary key}, which is every part of a
  # column definition a rebuild could silently change.
  defp table_info do
    %{rows: rows} = sql!("PRAGMA table_info('media_items')")

    Map.new(rows, fn [_cid, name, type, notnull, default, pk] ->
      {name, {type, notnull, default, pk}}
    end)
  end

  defp named_indexes do
    %{rows: rows} =
      sql!("""
      SELECT name FROM sqlite_master
      WHERE type = 'index' AND tbl_name = 'media_items' AND name NOT LIKE 'sqlite_%'
      ORDER BY name
      """)

    List.flatten(rows)
  end

  # {referenced table, local column, referenced column, on delete}, sorted so
  # the assertion does not depend on SQLite's enumeration order.
  defp foreign_keys do
    %{rows: rows} = sql!("PRAGMA foreign_key_list('media_items')")

    # The pragma's columns are id, seq, table, from, to, on_update, on_delete,
    # match. Reading position 5 gets on_update, which is `NO ACTION` on every
    # one of these and would make the assertion pass for the wrong reason.
    rows
    |> Enum.map(fn [_id, _seq, table, from, to, _on_update, on_delete | _] ->
      {table, from, to, on_delete}
    end)
    |> Enum.sort()
  end

  defp index_origins do
    %{rows: rows} = sql!("PRAGMA index_list('media_items')")

    Enum.map(rows, &Enum.at(&1, 3))
  end

  defp insert_item(id, type, title, ids) do
    sql!(
      """
      INSERT INTO media_items (id, type, title, tmdb_id, tvdb_id, inserted_at, updated_at)
      VALUES (?1, ?2, ?3, ?4, ?5, '2026-09-06 00:00:00', '2026-09-06 00:00:00')
      """,
      [id, type, title, ids[:tmdb_id], ids[:tvdb_id]]
    )
  end
end
