defmodule Mydia.Repo.Migrations.ScopeProviderIdUniquenessByType do
  use Ecto.Migration

  @moduledoc """
  TMDB and TVDB number movies and series in independent namespaces, so a global
  unique index on `tmdb_id` treats a movie and a show that legitimately share a
  number as conflicting rows.

  `up` needs no data step. A composite unique index on `(type, tmdb_id)` is
  strictly weaker than a global one on `tmdb_id`: every row that satisfied the
  old index satisfies the new one.

  `down` is the direction that can fail, once a library has taken advantage of
  the relaxation. It checks first and refuses with the offending ids named,
  rather than letting the adapter raise a bare unique violation partway through
  and leaving the operator to work out which rows are at fault.

  Both indexes are partial. That is not cosmetic. SQLite reports a partial
  unique index violation as `UNIQUE constraint failed: index 'name'` and a plain
  composite one as a column list, which `ecto_sqlite3` rewrites into an
  Ecto-convention name. Keeping them partial makes SQLite and PostgreSQL report
  the same literal index name, which is what `MediaItem.changeset/2`'s
  `unique_constraint` calls have to match.

  The drops are `drop_if_exists` because `media_items_tmdb_id_index` is not
  present on every install. Until 2025-11-24 the table was created by a raw
  `CREATE TABLE` carrying `tmdb_id INTEGER UNIQUE` inline, so SQLite enforced
  the uniqueness through `sqlite_autoindex_media_items_2` and no named index
  ever existed. A plain `drop` raised `no such index` on those databases, and
  since `Ecto.Migrator` sits in the supervision tree that is a boot loop, not a
  failed upgrade.

  Removing that inline constraint needs a table rebuild, which this migration
  deliberately does not attempt. On such an install the composite indexes are
  created and correct, but the surviving column-level `UNIQUE` still keeps a
  movie and a show from sharing a `tmdb_id`.
  """

  def up do
    drop_if_exists unique_index(:media_items, [:tmdb_id], name: :media_items_tmdb_id_index)
    drop_if_exists unique_index(:media_items, [:tvdb_id], name: :media_items_tvdb_id_index)

    create unique_index(:media_items, [:type, :tmdb_id],
             where: "tmdb_id IS NOT NULL",
             name: :media_items_type_tmdb_id_index
           )

    create unique_index(:media_items, [:type, :tvdb_id],
             where: "tvdb_id IS NOT NULL",
             name: :media_items_type_tvdb_id_index
           )
  end

  def down do
    # Both guards run before any DDL, so a refusal leaves the schema untouched
    # whether or not the adapter wraps migrations in a transaction.
    guard_no_cross_type_duplicates!("tmdb_id")
    guard_no_cross_type_duplicates!("tvdb_id")

    drop unique_index(:media_items, [:type, :tmdb_id], name: :media_items_type_tmdb_id_index)
    drop unique_index(:media_items, [:type, :tvdb_id], name: :media_items_type_tvdb_id_index)

    create unique_index(:media_items, [:tmdb_id], name: :media_items_tmdb_id_index)

    create unique_index(:media_items, [:tvdb_id],
             where: "tvdb_id IS NOT NULL",
             name: :media_items_tvdb_id_index
           )
  end

  # `column` is a literal from this module's own call sites, never user input.
  defp guard_no_cross_type_duplicates!(column) do
    %{rows: rows} =
      repo().query!("""
      SELECT #{column}, MIN(type || ': ' || title), MAX(type || ': ' || title)
      FROM media_items
      WHERE #{column} IS NOT NULL
      GROUP BY #{column}
      HAVING COUNT(DISTINCT type) > 1
      """)

    if rows != [] do
      detail =
        Enum.map_join(rows, "\n", fn [id, first, second] ->
          "  #{column} #{id}: #{first} / #{second}"
        end)

      raise Ecto.MigrationError, """
      Cannot roll back: #{length(rows)} provider id(s) are held by media items of more than one type.

      #{detail}

      The global unique index this rollback restores cannot hold them. Delete one
      row of each listed pair, or clear its #{column}, then run the rollback again.
      """
    end
  end
end
