defmodule Mydia.Repo.Migrations.CreateMediaFileMatchCandidates do
  use Ecto.Migration

  def change do
    # Caches what the matcher found for a file so the review inbox never has to
    # re-query the metadata relay for work a previous run already paid for. This
    # is deliberately a separate table rather than columns on media_files: that
    # table will hold hundreds of thousands of rows in a large library, and the
    # review UI picks among several results, which needs a one-to-many shape.
    create table(:media_file_match_candidates, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :media_file_id,
          references(:media_files, type: :binary_id, on_delete: :delete_all),
          null: false

      # 0 is the best candidate. Rank exists so the inbox can offer runners-up
      # without a second relay round trip.
      add :rank, :integer, null: false, default: 0

      # All nullable: a row with no provider records a match failure, which is
      # what drives the "tried and could not identify this" state in the inbox.
      add :provider_type, :text
      add :provider_id, :text
      add :title, :text
      add :year, :integer
      add :media_type, :text
      add :confidence, :float

      # Season, episodes, and the sample/trailer/extra flags from ReleaseParser.
      add :parsed_info, :text

      add :attempts, :integer, null: false, default: 0
      add :last_error, :text

      timestamps(type: :utc_datetime)
    end

    create index(:media_file_match_candidates, [:media_file_id])

    # One row per rank per file, which also lets the write be an atomic upsert
    # so a retried match never doubles up.
    create unique_index(:media_file_match_candidates, [:media_file_id, :rank])
  end
end
