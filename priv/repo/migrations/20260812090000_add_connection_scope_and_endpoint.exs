defmodule Mydia.Repo.Migrations.AddConnectionScopeAndEndpoint do
  use Ecto.Migration

  import Mydia.Repo.Migrations.Helpers

  # An instance-scoped connection is an operator-configured service endpoint: it
  # has no user, it stores a candidate address list rather than one frozen URL,
  # and it says how to attach its secret. `user_id` therefore stops being
  # required, which forces the unique index to change shape: a composite over a
  # nullable column enforces nothing for the rows that have the NULL, because
  # NULL never equals NULL on either engine. Two partial indexes do enforce it.
  def up do
    alter table(:plugin_user_connections) do
      add :scope, :string, null: false, default: "user"
      add :label, :string, null: false, default: ""
      add :base_urls, :text
      add :resolved_base_url, :string
      add :auth_kind, :string, null: false, default: "bearer"
      add :auth_key, :string
    end

    if postgres?() do
      execute "DROP INDEX IF EXISTS plugin_user_connections_plugin_slug_user_id_index"
      execute "ALTER TABLE plugin_user_connections ALTER COLUMN user_id DROP NOT NULL"

      create unique_index(:plugin_user_connections, [:plugin_slug, :user_id, :label],
               where: "user_id IS NOT NULL",
               name: :plugin_user_connections_user_label_index
             )

      create unique_index(:plugin_user_connections, [:plugin_slug, :label],
               where: "user_id IS NULL",
               name: :plugin_user_connections_instance_label_index
             )
    else
      # SQLite cannot ALTER COLUMN, so the table is rebuilt. recreate_table/1
      # recreates ONLY the indexes listed here, so all three originals must be
      # restated or they are silently lost.
      recreate_table(
        table: :plugin_user_connections,
        primary_key: false,
        timestamps: [type: :utc_datetime_usec],
        columns: [
          {:id, :binary_id, [primary_key: true]},
          {:plugin_config_id, :binary_id,
           [
             null: false,
             references: {:plugin_configs, [type: :binary_id, on_delete: :delete_all]}
           ]},
          {:plugin_slug, :string, [null: false]},
          {:user_id, :binary_id,
           [references: {:users, [type: :binary_id, on_delete: :delete_all]}]},
          {:status, :string, [null: false, default: "connected"]},
          {:access_token, :string, []},
          {:external_user_id, :string, []},
          {:external_username, :string, []},
          {:meta, :text, []},
          {:scope, :string, [null: false, default: "user"]},
          {:label, :string, [null: false, default: ""]},
          {:base_urls, :text, []},
          {:resolved_base_url, :string, []},
          {:auth_kind, :string, [null: false, default: "bearer"]},
          {:auth_key, :string, []}
        ],
        indexes: [
          {[:plugin_slug], []},
          {[:user_id], []},
          {[:plugin_slug, :user_id, :label],
           [
             unique: true,
             where: "user_id IS NOT NULL",
             name: :plugin_user_connections_user_label_index
           ]},
          {[:plugin_slug, :label],
           [
             unique: true,
             where: "user_id IS NULL",
             name: :plugin_user_connections_instance_label_index
           ]}
        ]
      )
    end
  end

  def down do
    execute "DELETE FROM plugin_user_connections WHERE user_id IS NULL"

    if postgres?() do
      execute "DROP INDEX IF EXISTS plugin_user_connections_user_label_index"
      execute "DROP INDEX IF EXISTS plugin_user_connections_instance_label_index"
      execute "ALTER TABLE plugin_user_connections ALTER COLUMN user_id SET NOT NULL"
      create unique_index(:plugin_user_connections, [:plugin_slug, :user_id])
    else
      recreate_table(
        table: :plugin_user_connections,
        primary_key: false,
        timestamps: [type: :utc_datetime_usec],
        columns: [
          {:id, :binary_id, [primary_key: true]},
          {:plugin_config_id, :binary_id,
           [
             null: false,
             references: {:plugin_configs, [type: :binary_id, on_delete: :delete_all]}
           ]},
          {:plugin_slug, :string, [null: false]},
          {:user_id, :binary_id,
           [
             null: false,
             references: {:users, [type: :binary_id, on_delete: :delete_all]}
           ]},
          {:status, :string, [null: false, default: "connected"]},
          {:access_token, :string, []},
          {:external_user_id, :string, []},
          {:external_username, :string, []},
          {:meta, :text, []}
        ],
        indexes: [
          {[:plugin_slug], []},
          {[:user_id], []},
          {[:plugin_slug, :user_id], [unique: true]}
        ]
      )
    end

    if postgres?() do
      alter table(:plugin_user_connections) do
        remove :scope
        remove :label
        remove :base_urls
        remove :resolved_base_url
        remove :auth_kind
        remove :auth_key
      end
    end
  end
end
