defmodule Mydia.Repo.Migrations.PluginContract14 do
  use Ecto.Migration
  import Ecto.Query

  @moduledoc """
  Host contract 1.4: plugin instances and account links.

  * `plugin_instances` holds per-instance operator settings, approved private
    endpoints and proposed remote accounts. Every existing plugin config gets
    one default instance carrying its settings and schedule state.
  * `plugin_account_links` replaces `plugin_user_connections`. A link belongs
    to an instance, has a role (owner, endpoint, user) and a source, and its
    user is optional (owner and endpoint links have none). Existing rows are
    copied as user links; status "connected" becomes "active".
  * `plugin_kv` and `plugin_logs` gain `instance_id`. KV uniqueness moves from
    (slug, key) to (instance, key) so two instances of one plugin never share
    state.

  The legacy table is copied and dropped rather than rebuilt in place because
  `user_id` must become nullable, which SQLite cannot alter. Nothing references
  `plugin_user_connections`, so dropping it fires no foreign key actions.
  """

  def up do
    create table(:plugin_instances, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :plugin_config_id,
          references(:plugin_configs, type: :binary_id, on_delete: :delete_all)

      add :plugin_slug, :text, null: false
      add :name, :text, null: false
      add :enabled, :boolean, null: false, default: true
      add :settings, :text
      add :approved_endpoints, :text
      add :remote_accounts, :text
      add :last_scheduled_at, :utc_datetime_usec
      add :schedule_failures, :integer, null: false, default: 0
      # Set only for instances declared in YAML/env (Task 11); the declared name.
      add :runtime_key, :text

      timestamps(type: :utc_datetime_usec)
    end

    create index(:plugin_instances, [:plugin_slug])
    create index(:plugin_instances, [:plugin_config_id])
    # NULLs are distinct on both adapters, so DB-created instances never collide.
    create unique_index(:plugin_instances, [:plugin_slug, :runtime_key])

    create table(:plugin_account_links, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :instance_id, references(:plugin_instances, type: :binary_id, on_delete: :delete_all),
        null: false

      add :plugin_slug, :text, null: false
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all)
      add :role, :text, null: false, default: "user"
      add :source, :text, null: false, default: "user_flow"
      add :status, :text, null: false, default: "active"
      add :access_token, :text
      add :external_user_id, :text
      add :external_username, :text
      add :last_error, :text
      add :meta, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:plugin_account_links, [:instance_id, :user_id],
             where: "user_id IS NOT NULL",
             name: :plugin_account_links_instance_user_index
           )

    create unique_index(:plugin_account_links, [:instance_id, :external_user_id],
             where: "role = 'user' AND external_user_id IS NOT NULL",
             name: :plugin_account_links_instance_external_index
           )

    create unique_index(:plugin_account_links, [:instance_id, :role],
             where: "role IN ('owner', 'endpoint')",
             name: :plugin_account_links_instance_credential_index
           )

    create index(:plugin_account_links, [:plugin_slug])
    create index(:plugin_account_links, [:user_id])

    alter table(:plugin_kv) do
      add :instance_id, references(:plugin_instances, type: :binary_id, on_delete: :delete_all)
    end

    alter table(:plugin_logs) do
      add :instance_id, references(:plugin_instances, type: :binary_id, on_delete: :delete_all)
    end

    flush()
    backfill()

    drop_if_exists unique_index(:plugin_kv, [:plugin_slug, :key])
    create unique_index(:plugin_kv, [:instance_id, :key])
    create index(:plugin_logs, [:instance_id, :inserted_at])

    drop_if_exists table(:plugin_user_connections)
  end

  # Irreversible: links created after the upgrade (owner, endpoint, admin-mapped)
  # have no place in the old table, and instances beyond the default would lose
  # their state.
  def down, do: raise(Ecto.MigrationError, message: "20260929141207 is irreversible")

  @doc false
  def backfill do
    create_default_instances()
    backfill_instance_ids("plugin_kv", "plugin_config_id")
    backfill_log_instance_ids()
    copy_legacy_connections()
    :ok
  end

  defp create_default_instances do
    have = MapSet.new(query_repo().all(from(i in "plugin_instances", select: i.plugin_slug)))
    now = DateTime.utc_now()

    rows =
      from(c in "plugin_configs",
        select: %{
          id: c.id,
          slug: c.slug,
          name: c.name,
          settings: c.settings,
          last_scheduled_at: c.last_scheduled_at,
          failures: c.consecutive_schedule_failures
        }
      )
      |> query_repo().all()
      |> Enum.reject(&MapSet.member?(have, &1.slug))
      |> Enum.map(fn c ->
        %{
          id: new_uuid(),
          plugin_config_id: c.id,
          plugin_slug: c.slug,
          name: c.name,
          # `enabled` is left to the column default: a schemaless boolean insert
          # is stored as the text "true" on SQLite and then fails to load.
          settings: c.settings,
          approved_endpoints: "[]",
          remote_accounts: "[]",
          last_scheduled_at: c.last_scheduled_at,
          schedule_failures: c.failures || 0,
          inserted_at: now,
          updated_at: now
        }
      end)

    if rows != [], do: query_repo().insert_all("plugin_instances", rows)
  end

  defp backfill_instance_ids(table, fk) do
    query_repo().query!("""
    UPDATE #{table} SET instance_id = (
      SELECT i.id FROM plugin_instances i WHERE i.plugin_config_id = #{table}.#{fk}
    )
    WHERE instance_id IS NULL
    """)
  end

  defp backfill_log_instance_ids do
    query_repo().query!("""
    UPDATE plugin_logs SET instance_id = (
      SELECT i.id FROM plugin_instances i WHERE i.plugin_slug = plugin_logs.slug
      ORDER BY i.inserted_at LIMIT 1
    )
    WHERE instance_id IS NULL
    """)
  end

  defp copy_legacy_connections do
    if table_exists?("plugin_user_connections") do
      query_repo().query!("""
      INSERT INTO plugin_account_links
        (id, instance_id, plugin_slug, user_id, role, source, status, access_token,
         external_user_id, external_username, last_error, meta, inserted_at, updated_at)
      SELECT c.id, i.id, c.plugin_slug, c.user_id, 'user', 'user_flow',
             CASE c.status WHEN 'connected' THEN 'active' ELSE c.status END,
             c.access_token, c.external_user_id, c.external_username, NULL, c.meta,
             c.inserted_at, c.updated_at
      FROM plugin_user_connections c
      JOIN plugin_instances i ON i.plugin_config_id = c.plugin_config_id
      WHERE NOT EXISTS (SELECT 1 FROM plugin_account_links l WHERE l.id = c.id)
      """)
    end
  end

  defp table_exists?(name) do
    sql =
      if postgres?(),
        do: "SELECT to_regclass($1) IS NOT NULL",
        else: "SELECT COUNT(*) > 0 FROM sqlite_master WHERE type = 'table' AND name = $1"

    case query_repo().query!(sql, [name]) do
      %{rows: [[v]]} -> v in [true, 1]
    end
  end

  defp new_uuid do
    uuid = Ecto.UUID.generate()
    if postgres?(), do: Ecto.UUID.dump!(uuid), else: uuid
  end

  defp postgres?, do: query_repo().__adapter__() == Ecto.Adapters.Postgres

  # `repo/0` only works inside a migration runner; tests call backfill/0 directly.
  defp query_repo do
    case Process.get(:ecto_migration) do
      %{runner: _} -> repo()
      _ -> Mydia.Repo
    end
  end
end
