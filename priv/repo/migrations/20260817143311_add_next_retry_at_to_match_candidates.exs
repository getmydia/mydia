defmodule Mydia.Repo.Migrations.AddNextRetryAtToMatchCandidates do
  use Ecto.Migration

  def change do
    alter table(:media_file_match_candidates) do
      add :next_retry_at, :utc_datetime
    end

    create index(:media_file_match_candidates, [:next_retry_at])
  end
end
