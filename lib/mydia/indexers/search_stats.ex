defmodule Mydia.Indexers.SearchStats do
  @moduledoc """
  Per-indexer search metrics, read from `indexer_search_events`.

  Rows are written by `Mydia.Indexers.SearchStats.Recorder` from the
  `Mydia.Indexers.SearchStats.Telemetry` event and pruned after
  14 days (`@retention_days`) by `Mydia.Jobs.IndexerStatsCleanup`. Aggregation happens in
  Elixir so the queries stay plain, portable SQL.
  """

  import Ecto.Query

  alias Mydia.Indexers.SearchStats.{Event, Summary}
  alias Mydia.Repo

  @retention_days 14

  @type window :: :day | :week

  @doc "Summaries per indexer id, one per engine, busiest first."
  @spec summary(window(), String.t()) :: %{String.t() => [Summary.t()]}
  def summary(window, kind \\ "search") do
    since = DateTime.add(DateTime.utc_now(), -window_seconds(window), :second)

    from(e in Event,
      where: e.kind == ^kind and e.inserted_at >= ^since,
      select: {e.indexer_id, e.engine, e.outcome, e.duration_ms, e.result_count}
    )
    |> Repo.all()
    |> Enum.group_by(fn {indexer_id, engine, _, _, _} -> {indexer_id, engine} end)
    |> Enum.map(fn {{indexer_id, engine}, rows} -> Summary.build(indexer_id, engine, rows) end)
    |> Enum.group_by(& &1.indexer_id)
    |> Map.new(fn {indexer_id, summaries} ->
      {indexer_id, Enum.sort_by(summaries, & &1.attempts, :desc)}
    end)
  end

  @doc "The newest failed calls for one indexer, searches and health probes alike."
  @spec recent_failures(String.t(), pos_integer()) :: [Event.t()]
  def recent_failures(indexer_id, limit \\ 10) do
    from(e in Event,
      where: e.indexer_id == ^indexer_id and e.outcome != "ok",
      order_by: [desc: e.inserted_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc "Deletes rows older than the retention window; returns how many."
  @spec prune(DateTime.t()) :: non_neg_integer()
  def prune(now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -@retention_days * 86_400, :second)
    {count, _} = Repo.delete_all(from(e in Event, where: e.inserted_at < ^cutoff))
    count
  end

  defp window_seconds(:day), do: 86_400
  defp window_seconds(:week), do: 7 * 86_400
end
