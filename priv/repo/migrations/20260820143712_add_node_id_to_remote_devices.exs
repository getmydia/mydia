defmodule Mydia.Repo.Migrations.AddNodeIdToRemoteDevices do
  use Ecto.Migration

  def change do
    # :text rather than :string. A bare :string is varchar(255) on PostgreSQL
    # and unconstrained TEXT on SQLite, which has shipped the same bug twice.
    alter table(:remote_devices) do
      add :node_id, :text
    end

    # Deliberately not unique. A device that re-pairs reuses its persisted
    # keypair, so a stale revoked row can hold the same node id, and a unique
    # index would turn that into a pairing failure.
    create index(:remote_devices, [:node_id])
  end
end
