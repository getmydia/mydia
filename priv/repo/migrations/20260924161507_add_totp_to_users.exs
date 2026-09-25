defmodule Mydia.Repo.Migrations.AddTotpToUsers do
  @moduledoc """
  TOTP two-factor authentication: the encrypted secret, when it was enabled,
  and the last accepted 30-second step (replay guard) on `users`, plus one row
  per single-use recovery code.
  """
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :totp_secret_encrypted, :text
      add :totp_enabled_at, :utc_datetime
      add :totp_last_used_at, :utc_datetime
    end

    create table(:user_recovery_codes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :code_hash, :text, null: false
      add :used_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:user_recovery_codes, [:user_id])
  end
end
