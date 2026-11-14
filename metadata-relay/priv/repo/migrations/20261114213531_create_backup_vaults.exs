defmodule MetadataRelay.Repo.Migrations.CreateBackupVaults do
  use Ecto.Migration

  def change do
    create table(:backup_vaults, primary_key: false) do
      add :id, :text, primary_key: true
      add :epoch, :integer, null: false
      add :lookup_hash, :text, null: false
      add :recovery_signer, :text, null: false
      add :recovery_envelope, :text, null: false
      add :last_write_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:backup_vaults, [:lookup_hash])
    create index(:backup_vaults, [:last_write_at])

    create table(:backup_members, primary_key: false) do
      add :vault_id, references(:backup_vaults, type: :text, on_delete: :delete_all),
        null: false

      add :signer, :text, null: false
      add :slot_id, :text, null: false
      add :envelope, :text, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:backup_members, [:vault_id, :signer])
    create unique_index(:backup_members, [:vault_id, :slot_id])
    create index(:backup_members, [:signer])

    create table(:backup_slots, primary_key: false) do
      add :vault_id, references(:backup_vaults, type: :text, on_delete: :delete_all),
        null: false,
        primary_key: true

      add :slot_id, :text, null: false, primary_key: true
      add :seq, :integer, null: false
      add :epoch, :integer, null: false
      add :size, :integer, null: false
      add :path, :text, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end
  end
end
