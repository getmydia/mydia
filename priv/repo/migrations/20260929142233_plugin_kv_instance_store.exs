defmodule Mydia.Repo.Migrations.PluginKvInstanceStore do
  use Ecto.Migration

  import Mydia.Repo.Migrations.Helpers

  # The plugin KV becomes a per-instance store (contract 1.4). 20260929141207
  # already added instance_id and moved the unique index to (instance_id, key).
  # This adds the two things the store quotas need:
  #
  #   * `size_bytes` caches byte_size(key) + byte_size(value) per row so the
  #     byte quota is one SUM instead of re-measuring every value.
  #   * `key` and `plugin_slug` were created as :string, which is varchar(255)
  #     on PostgreSQL and shorter than the 512-byte key cap. Widen to text.
  #     SQLite already stores them as TEXT, so this is PostgreSQL-only.
  def up do
    alter table(:plugin_kv) do
      add :size_bytes, :integer, null: false, default: 0
    end

    flush()

    if postgres?() do
      execute("ALTER TABLE plugin_kv ALTER COLUMN key TYPE text")
      execute("ALTER TABLE plugin_kv ALTER COLUMN plugin_slug TYPE text")

      execute(
        "UPDATE plugin_kv SET size_bytes = octet_length(key) + coalesce(octet_length(value), 0)"
      )
    else
      execute(
        "UPDATE plugin_kv SET size_bytes = length(CAST(key AS BLOB)) + coalesce(length(CAST(value AS BLOB)), 0)"
      )
    end

    # Every set/set-many measures the instance with count(*) and sum(size_bytes);
    # this covers both aggregates so they never read the value column.
    create index(:plugin_kv, [:instance_id, :size_bytes], name: :plugin_kv_instance_size_index)
  end

  # The text widening is kept on rollback: narrowing back to varchar(255)
  # could truncate keys written after the upgrade.
  def down do
    drop_if_exists index(:plugin_kv, [:instance_id, :size_bytes],
                     name: :plugin_kv_instance_size_index
                   )

    alter table(:plugin_kv) do
      remove :size_bytes
    end
  end
end
