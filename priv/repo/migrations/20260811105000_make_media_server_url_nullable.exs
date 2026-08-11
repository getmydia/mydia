defmodule Mydia.Repo.Migrations.MakeMediaServerUrlNullable do
  @moduledoc """
  Make media_server_configs.url nullable.

  For Plex, url is a manual operator override. Discovery stores the full
  connections list and Endpoint.resolve/1 picks a working address at call
  time, so oauth setup leaves url nil.
  """
  use Ecto.Migration
  import Mydia.Repo.Migrations.Helpers

  @columns [
    {:id, :binary_id, [primary_key: true]},
    {:name, :string, [null: false]},
    {:type, :string, [null: false]},
    {:enabled, :boolean, [default: true]},
    {:url, :string, []},
    {:token, :string, []},
    {:connection_settings, :text, []},
    {:machine_identifier, :string, []},
    {:connections, :text, []},
    {:server_access_token, :string, []},
    {:last_auth_error, :string, []},
    {:last_auth_error_at, :utc_datetime, []},
    {:updated_by_id, :binary_id,
     [references: {:users, [type: :binary_id, on_delete: :nilify_all]}]}
  ]

  @indexes [
    {[:name], [unique: true]},
    [:enabled],
    [:type],
    [:machine_identifier]
  ]

  def up do
    modify_columns_null(
      table: :media_server_configs,
      changes: [{:url, true}],
      columns: @columns,
      indexes: @indexes
    )
  end

  def down do
    modify_columns_null(
      table: :media_server_configs,
      changes: [{:url, false}],
      columns:
        Enum.map(@columns, fn
          {:url, type, _opts} -> {:url, type, [null: false]}
          other -> other
        end),
      indexes: @indexes
    )
  end
end
