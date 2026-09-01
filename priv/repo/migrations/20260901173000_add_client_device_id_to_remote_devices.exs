defmodule Mydia.Repo.Migrations.AddClientDeviceIdToRemoteDevices do
  use Ecto.Migration

  @moduledoc """
  Records the stable identifier a client generates for itself.

  `remote_devices.id` is a server-side UUID, so before this column there was
  nothing to match a returning client against and a password login had no way
  to find its own row. Nullable because every device paired before this
  migration has no client identifier and must keep working.
  """

  def change do
    alter table(:remote_devices) do
      # `:text`, never `:string`: a bare `:string` is varchar(255) on
      # PostgreSQL and unconstrained TEXT on SQLite, so an over-long write
      # passes in development and fails in production.
      add :client_device_id, :text
    end

    # Scoped to the user so two accounts on one machine keep separate rows.
    create unique_index(:remote_devices, [:user_id, :client_device_id])
  end
end
