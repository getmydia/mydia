defmodule Mydia.Repo.Migrations.MoveRemoteAccessEnabledToConfigSettings do
  @moduledoc """
  Moves the remote-access on/off switch from `remote_access_config.enabled` into
  the layered config, as the `remote_access.enabled` row of `config_settings`.

  Only a `false` is carried over. `true` is the new default, and since
  `20260819171533` switched every existing row on, a `false` can only mean an
  administrator turned remote access off afterwards. That choice has to survive
  the upgrade: dropping it would put the p2p node back on the network on an
  install whose operator took it off.

  Then the column goes, as `20260819171204` dropped columns from this table.
  Nothing indexes it, so SQLite can drop it in place.
  """

  use Ecto.Migration

  import Mydia.Repo.Migrations.Helpers

  @key "remote_access.enabled"

  def up do
    # repo().query!/2 runs now; the alter below is queued and runs after up/0
    # returns, so the column is still there to read.
    if legacy_disabled?(), do: insert_disabled_setting()

    alter table(:remote_access_config) do
      remove :enabled
    end
  end

  def down do
    disabled? = disabled_setting?()

    alter table(:remote_access_config) do
      add :enabled, :boolean, default: true, null: false
    end

    if disabled?, do: execute_update(:remote_access_config, enabled: false)

    execute("DELETE FROM config_settings WHERE key = '#{@key}'")
  end

  # Oldest row wins, matching Mydia.RemoteAccess.get_config/0.
  defp legacy_disabled? do
    %{rows: rows} =
      repo().query!(
        "SELECT enabled FROM remote_access_config ORDER BY inserted_at ASC, id ASC LIMIT 1"
      )

    case rows do
      [[enabled]] -> enabled in [false, 0]
      _ -> false
    end
  end

  defp disabled_setting? do
    %{rows: rows} =
      repo().query!("SELECT value FROM config_settings WHERE key = $1", [@key])

    rows == [["false"]]
  end

  # Postgres stores binary_id as uuid and wants the 16-byte form; SQLite stores
  # it as text.
  defp insert_disabled_setting do
    id = if postgres?(), do: Ecto.UUID.bingenerate(), else: Ecto.UUID.generate()
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    repo().query!(
      """
      INSERT INTO config_settings (id, key, value, category, inserted_at, updated_at)
      VALUES ($1, $2, 'false', 'remote_access', $3, $3)
      ON CONFLICT (key) DO NOTHING
      """,
      [id, @key, now]
    )
  end
end
