defmodule Mydia.Repo.Migrations.AddReturnedAtToImportCandidates do
  use Ecto.Migration

  # Set by Mydia.ImportCandidates.return_to_review/2 when an operator detaches
  # a misattached file. Nullable with no default, so adding it needs no table
  # rebuild on SQLite.
  def change do
    alter table(:import_candidates) do
      add :returned_at, :utc_datetime
    end
  end
end
