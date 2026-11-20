defmodule Mydia.Jobs.RateLimitDeferral do
  @moduledoc """
  What the background search jobs (`Mydia.Jobs.MovieSearch`,
  `Mydia.Jobs.TVShowSearch`) share about an empty search: whether it was only
  deferred by rate limits, and how many indexers a search covers.

  A search that found nothing because every indexer was rate-limited (a 429,
  a cooldown, Mydia's per-minute limit or a daily cap) says nothing about
  whether releases exist, so the jobs record no backoff and no "no results"
  event for it. Not to be confused with `Mydia.Jobs.SearchDeferral`, which
  delays grabs.
  """

  alias Mydia.Indexers

  require Logger

  @doc """
  True, after logging the deferral with `meta`, when `search_result` (from
  `Mydia.Indexers.search_all/2`) is empty only because every indexer was
  rate-limited.
  """
  @spec deferred?(map(), keyword()) :: boolean()
  def deferred?(search_result, meta) do
    deferred = Indexers.deferred_by_rate_limits?(search_result)
    if deferred, do: Logger.info("Search deferred: every indexer is rate-limited", meta)
    deferred
  end

  @doc "Enabled indexer configs plus, when the feature is on, enabled Cardigann definitions."
  @spec count_enabled_indexers() :: non_neg_integer()
  def count_enabled_indexers do
    enabled_count = Enum.count(Mydia.Settings.list_indexer_configs(), & &1.enabled)

    cardigann_count =
      if Application.get_env(:mydia, :features, [])[:cardigann_indexers] do
        Enum.count(Indexers.list_cardigann_definitions(), & &1.enabled)
      else
        0
      end

    enabled_count + cardigann_count
  end
end
