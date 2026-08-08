defmodule MetadataRelay.Repo.Migrations.CreateP2pAccessTables do
  use Ecto.Migration

  def change do
    create table(:p2p_endpoint_sightings, primary_key: false) do
      add(:endpoint_id, :string, primary_key: true)
      add(:first_seen, :utc_datetime, null: false)
      add(:last_seen, :utc_datetime, null: false)
      add(:conn_count, :integer, null: false, default: 0)
    end

    create(index(:p2p_endpoint_sightings, [:last_seen]))

    create table(:p2p_blocked_endpoints, primary_key: false) do
      add(:endpoint_id, :string, primary_key: true)
      add(:reason, :string)
      add(:blocked_at, :utc_datetime, null: false)
    end
  end
end
