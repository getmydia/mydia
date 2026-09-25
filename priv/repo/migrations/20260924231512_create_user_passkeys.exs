defmodule Mydia.Repo.Migrations.CreateUserPasskeys do
  @moduledoc """
  WebAuthn passkeys. One row per credential; `rp_id` is the host it was
  registered on, since a passkey only works on that host.
  """
  use Ecto.Migration

  def change do
    create table(:user_passkeys, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :credential_id, :text, null: false
      add :public_key, :binary, null: false
      add :rp_id, :text, null: false
      add :sign_count, :integer, null: false, default: 0
      add :aaguid, :text
      add :transports, :text, null: false, default: "[]"
      add :name, :text, null: false
      add :last_used_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:user_passkeys, [:credential_id])
    create index(:user_passkeys, [:user_id])
  end
end
