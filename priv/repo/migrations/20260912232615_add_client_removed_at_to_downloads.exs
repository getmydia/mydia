defmodule Mydia.Repo.Migrations.AddClientRemovedAtToDownloads do
  use Ecto.Migration

  # Purely additive: one new column. No ALTER COLUMN, so this needs no
  # SQLite/Postgres branching.
  def change do
    alter table(:downloads) do
      add :client_removed_at, :utc_datetime
    end
  end
end
