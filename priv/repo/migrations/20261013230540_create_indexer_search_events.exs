defmodule Mydia.Repo.Migrations.CreateIndexerSearchEvents do
  @moduledoc """
  One row per indexer call (a search or a Cardigann health probe), written by
  `Mydia.Indexers.SearchStats.Recorder` and pruned after 14 days by
  `Mydia.Jobs.IndexerStatsCleanup`.

  `indexer_id` has no foreign key: it holds either an indexer config id or a
  Cardigann definition id, which live in different tables. `indexer_name` is a
  snapshot so rows for a renamed or deleted indexer still read.
  """
  use Ecto.Migration

  def change do
    create table(:indexer_search_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :indexer_id, :text, null: false
      add :indexer_name, :text, null: false
      add :indexer_type, :text, null: false
      add :engine, :text
      add :kind, :text, null: false
      add :outcome, :text, null: false
      add :error_message, :text
      add :duration_ms, :integer, null: false
      add :network_ms, :integer
      add :result_count, :integer, null: false, default: 0
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:indexer_search_events, [:indexer_id, :inserted_at])
    # Used by the daily prune.
    create index(:indexer_search_events, [:inserted_at])
  end
end
