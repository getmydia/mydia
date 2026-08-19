defmodule Mydia.Repo.Migrations.RemoveNoiseKeypairColumns do
  use Ecto.Migration

  # The static keypair columns held an X25519 "Noise protocol" identity that no
  # code has read since iroh took over the transport: the server writes a fresh
  # pair when remote access is enabled and pairing sends only the iroh node
  # address. `device_static_public_key` was filled with 32 random bytes per
  # device to satisfy its NOT NULL, and `relay_token` was never written at all.
  #
  # SQLite refuses to drop an indexed column, so its index goes first on both
  # adapters.

  def up do
    drop_if_exists index(:remote_devices, [:device_static_public_key])

    alter table(:remote_devices) do
      remove :device_static_public_key
    end

    alter table(:remote_access_config) do
      remove :static_public_key
      remove :static_private_key_encrypted
      remove :relay_token
    end
  end

  def down do
    # Re-added nullable: the originals were NOT NULL with no default, which no
    # existing row could satisfy on the way back.
    alter table(:remote_devices) do
      add :device_static_public_key, :binary
    end

    create index(:remote_devices, [:device_static_public_key])

    alter table(:remote_access_config) do
      add :static_public_key, :binary
      add :static_private_key_encrypted, :binary
      add :relay_token, :text
    end
  end
end
