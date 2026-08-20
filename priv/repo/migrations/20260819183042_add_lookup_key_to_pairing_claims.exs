defmodule Mydia.Repo.Migrations.AddLookupKeyToPairingClaims do
  use Ecto.Migration

  def change do
    # :text rather than :string. A bare :string is varchar(255) on PostgreSQL
    # and unconstrained TEXT on SQLite, which has shipped the same bug twice.
    alter table(:pairing_claims) do
      add :lookup_key, :text
    end

    # Claims are deleted from the relay by lookup key on consumption.
    create index(:pairing_claims, [:lookup_key])
  end
end
