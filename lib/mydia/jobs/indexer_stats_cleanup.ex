defmodule Mydia.Jobs.IndexerStatsCleanup do
  @moduledoc """
  Daily Oban worker that deletes indexer search events past retention.
  Scheduled from the Oban cron entry in `config/config.exs`.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3

  require Logger

  alias Mydia.Indexers.SearchStats

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    deleted = SearchStats.prune()
    Logger.info("Indexer search stats cleanup completed", deleted_count: deleted)
    :ok
  end
end
