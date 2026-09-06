defmodule Mydia.Repo.Migrations.DropLegacyMediaItemsTmdbInlineUnique do
  use Ecto.Migration

  import Mydia.Repo.Migrations.Helpers

  @moduledoc """
  Finishes what `20260905143012_scope_provider_id_uniqueness_by_type` started on
  databases created before 2025-11-24.

  That migration replaced the global unique index on `media_items.tmdb_id` with a
  composite one on `(type, tmdb_id)`, so a movie and a series that legitimately
  carry the same TMDB number stop colliding. It does that by dropping the named
  index and creating the composite one, which is the whole story on any database
  built from `20251104023000_create_media_items` in its current form.

  Older databases were built from that migration's original body, a raw
  `CREATE TABLE` carrying the constraint inline:

      tmdb_id INTEGER UNIQUE

  SQLite implements a column-level `UNIQUE` with an implicit
  `sqlite_autoindex_media_items_2`. There is no name to drop and no
  `ALTER TABLE ... DROP CONSTRAINT`, so the constraint survived
  `20260905143012` untouched. Those installs got the composite index, correct in
  itself, layered over a global uniqueness rule that still rejects the very rows
  the composite index exists to allow.

  Shedding a column constraint in SQLite means rebuilding the table, which is
  what this does, through `recreate_table/1` so the rebuild runs inside
  `preserving_fk_children/2`. `media_items` is the most-referenced table in the
  schema, and under `foreign_keys: :on` the rebuild's `DROP TABLE` would
  otherwise cascade through `media_files`, `seasons`, `downloads`,
  `playback_progress` and everything hanging off them.

  Two consequences of the rebuild worth stating plainly:

  - The `CHECK(type IN ('movie', 'tv_show'))` and `CHECK(monitored IN (0, 1))`
    constraints from the raw DDL are not carried over. Neither exists on a
    database created after the DSL conversion, so dropping them converges the
    two shapes rather than regressing one; `MediaItem.changeset/2` is where that
    validation lives on every install.
  - PostgreSQL never saw the raw form. Multi-adapter support arrived with the
    DSL conversion in `f9521c0c9`, so a Postgres database has always had the
    named index and needs nothing here.

  Two cosmetic differences fall out of rebuilding through the helper.
  `monitored` picks up `DEFAULT true` in place of the raw form's `DEFAULT 1`,
  which is the same value written the way every post-conversion install already
  writes it. And the foreign keys come out named `media_items_new_*`, because
  `recreate_table/1` builds under a temporary name and SQLite keeps the
  constraint names through the rename. `media_files`, `downloads` and
  `playback_progress` already carry that artifact from their own rebuilds;
  nothing reads these names on SQLite.

  The guard means this is a no-op on every database that does not carry the
  inline constraint, including one that has already run it.
  """

  def up do
    if sqlite?() and legacy_tmdb_inline_unique?() do
      recreate_table(
        table: :media_items,
        primary_key: false,
        columns: media_item_columns(),
        indexes: media_item_indexes(),
        postgres: :skip
      )
    end
  end

  # Deliberately irreversible. Restoring the inline `UNIQUE` means another
  # rebuild, and it would fail outright on any library that has since taken
  # advantage of the relaxation, which is the entire point of the change. The
  # composite indexes `20260905143012` created are untouched here, so rolling
  # that migration back still restores the uniqueness rule it knows about.
  def down, do: :ok

  # `origin` is `"u"` for an index SQLite created to back a `UNIQUE` declared in
  # `CREATE TABLE`, `"c"` for an explicit `CREATE INDEX`, and `"pk"` for the
  # primary key. Only the first kind is unreachable by name, and only that kind
  # justifies a rebuild.
  defp legacy_tmdb_inline_unique? do
    %{rows: rows} = repo().query!("PRAGMA index_list('media_items')")

    Enum.any?(rows, fn row ->
      name = Enum.at(row, 1)
      origin = Enum.at(row, 3)

      origin == "u" and indexed_columns(name) == ["tmdb_id"]
    end)
  end

  defp indexed_columns(index_name) do
    %{rows: rows} = repo().query!("PRAGMA index_info('#{index_name}')")

    Enum.map(rows, &Enum.at(&1, 2))
  end

  # The column set every install has by this point in the migration sequence.
  # `recreate_table/1` appends `inserted_at` and `updated_at` itself.
  defp media_item_columns do
    [
      # `null: false` is not decoration. SQLite lets a NULL into a TEXT PRIMARY
      # KEY unless the column says otherwise, and the raw DDL said otherwise.
      # Ecto's `primary_key: true` alone emits a bare `TEXT PRIMARY KEY`, so
      # leaving it off would quietly weaken the rebuilt table.
      {:id, :binary_id, [primary_key: true, null: false]},
      {:type, :text, [null: false]},
      {:title, :text, [null: false]},
      {:original_title, :text, []},
      {:year, :integer, []},
      {:tmdb_id, :integer, []},
      {:imdb_id, :text, []},
      {:metadata, :text, []},
      {:monitored, :boolean, [default: true]},
      {:quality_profile_id, :binary_id,
       [references: {:quality_profiles, [type: :binary_id, on_delete: :nilify_all]}]},
      {:category, :text, []},
      {:category_override, :boolean, [default: false, null: false]},
      {:seasons_refreshed_at, :utc_datetime, []},
      {:tvdb_id, :integer, []},
      {:metadata_source, :text, []},
      {:last_upgrade_check_at, :utc_datetime, []},
      {:library_path_id, :binary_id,
       [references: {:library_paths, [type: :binary_id, on_delete: :nilify_all]}]},
      {:monitor_new_seasons, :text, [default: "all"]},
      {:season_order, :text, []}
    ]
  end

  # Dropping the table drops its indexes with it, so every one has to be named
  # again here. The two composite ones are the pair `20260905143012` created;
  # they are partial for the reason its moduledoc gives, which is that SQLite
  # and PostgreSQL then report the same literal index name to
  # `MediaItem.changeset/2`.
  defp media_item_indexes do
    [
      [:imdb_id],
      [:title],
      [:type],
      [:quality_profile_id],
      [:category],
      [:last_upgrade_check_at],
      [:library_path_id],
      {[:type, :tmdb_id],
       [unique: true, where: "tmdb_id IS NOT NULL", name: :media_items_type_tmdb_id_index]},
      {[:type, :tvdb_id],
       [unique: true, where: "tvdb_id IS NOT NULL", name: :media_items_type_tvdb_id_index]}
    ]
  end
end
