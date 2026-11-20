defmodule Mydia.Repo.Migrations.AddHttpRequestsToIndexerSearchEvents do
  @moduledoc """
  HTTP requests one indexer call sent to the tracker
  (`Mydia.Indexers.SearchStats.Network`). Nullable: rows written before this
  column, deadline-killed searches and searches Mydia skipped have no count.
  """
  use Ecto.Migration

  def change do
    alter table(:indexer_search_events) do
      add :http_requests, :integer
    end
  end
end
