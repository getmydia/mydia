defmodule Mydia.Indexers.TrackerLimits do
  @moduledoc """
  Daily grab and search caps per tracker, from the `grab_limit` and
  `query_limit` of a `tracker_rules` entry (`Mydia.Indexers.TrackerRules`).
  Both count over a rolling 24 hours and are optional: Prowlarr may already
  enforce its own.

  * **Searches.** `guard_query/2` wraps one indexer's search in
    `Mydia.Indexers.search_all/2`. A rule applies to the Mydia indexer whose
    name matches the rule's tracker: a built-in Cardigann definition, or a
    Jackett or Torznab feed for a single tracker. An aggregate Prowlarr or
    Jackett connection sends one search to many trackers Mydia never sees, so
    trackers behind it rely on Prowlarr's limits. Every attempt counts, since
    the tracker saw the request either way. Counts live in
    `Mydia.Indexers.RateLimiter` (ETS) and reset on restart. At the cap the
    indexer is skipped with a rate-limited error, which manual search shows
    in the indexer's status.
  * **Grabs.** Counted from `downloads` rows whose `indexer` is the tracker,
    inserted in the last 24 hours, failed grabs included and removed rows
    not. Background searches (`skip_capped_trackers: true`, set by
    `Mydia.Indexers.background_search_opts/0`) drop a capped tracker's
    results before ranking; manual search keeps them and shows the reason on
    the row (`grab_caps/1`).

  See `lib/mydia/indexers/README.md`, "Tracker limits".
  """

  import Ecto.Query, warn: false

  alias Mydia.Downloads.Download
  alias Mydia.Indexers.{Adapter, RateLimiter, TrackerRules}
  alias Mydia.Repo

  require Logger

  @window_ms :timer.hours(24)
  @window_seconds 24 * 3600

  @typedoc "A reached grab cap: `{count, limit}`."
  @type cap :: {non_neg_integer(), non_neg_integer()}

  @doc """
  Runs `search_fun` (one indexer's search) unless the indexer's tracker is at
  its daily search cap, in which case it returns a rate-limited
  `Adapter.Error` without searching.
  """
  @spec guard_query(map(), (-> result)) :: result | {:error, Adapter.Error.t()}
        when result: term()
  def guard_query(config, search_fun) do
    case query_limit(config) do
      nil -> search_fun.()
      {key, limit} -> guarded_search(config, key, limit, search_fun)
    end
  end

  defp guarded_search(config, key, limit, search_fun) do
    case RateLimiter.reserve_window({:tracker_query, key}, limit, @window_ms) do
      :ok ->
        search_fun.()

      {:error, :limited, count} ->
        reason = "daily query limit reached (#{count}/#{limit})"
        Logger.info("Skipping indexer search: #{reason}", indexer: Map.get(config, :name))
        {:error, Adapter.Error.rate_limited(reason)}
    end
  end

  defp query_limit(config) do
    with name when is_binary(name) <- Map.get(config, :name),
         %{query_limit: limit} when is_integer(limit) <- TrackerRules.rule_for(name) do
      {TrackerRules.key(name), limit}
    else
      _ -> nil
    end
  end

  @doc """
  The trackers at their daily grab cap, keyed by `TrackerRules.key/1`, each
  with `{grabs in the last 24 hours, limit}`.
  """
  @spec grab_caps([Mydia.Settings.TrackerRuleConfig.t()]) :: %{String.t() => cap()}
  def grab_caps(rules \\ TrackerRules.list_rules()) do
    limits =
      for %{grab_limit: limit, tracker: tracker} <- rules, is_integer(limit), into: %{} do
        {TrackerRules.key(tracker), limit}
      end

    if limits == %{} do
      %{}
    else
      counts = grab_counts()

      limits
      |> Enum.map(fn {key, limit} -> {key, {Map.get(counts, key, 0), limit}} end)
      |> Enum.filter(fn {_key, {count, limit}} -> count >= limit end)
      |> Map.new()
    end
  end

  @doc "Grabs per tracker key in the last 24 hours."
  @spec grab_counts() :: %{String.t() => non_neg_integer()}
  def grab_counts do
    cutoff = DateTime.add(DateTime.utc_now(), -@window_seconds, :second)

    Download
    |> where([d], d.inserted_at >= ^cutoff and not is_nil(d.indexer))
    |> group_by([d], d.indexer)
    |> select([d], {d.indexer, count(d.id)})
    |> Repo.all()
    |> Enum.reduce(%{}, fn {indexer, count}, acc ->
      Map.update(acc, TrackerRules.key(indexer), count, &(&1 + count))
    end)
  end

  @doc "The grab cap `result`'s tracker has reached, or nil."
  @spec cap_for(%{:indexer => String.t() | nil, optional(atom()) => any()}, %{
          String.t() => cap()
        }) :: cap() | nil
  def cap_for(%{indexer: indexer}, caps), do: indexer && Map.get(caps, TrackerRules.key(indexer))

  @doc """
  Drops results from trackers at their grab cap when `opts` has
  `skip_capped_trackers: true` (background searches); otherwise returns
  `results` unchanged.
  """
  @spec drop_capped([map()], keyword()) :: [map()]
  def drop_capped(results, opts) do
    with true <- Keyword.get(opts, :skip_capped_trackers, false),
         caps when caps != %{} <- grab_caps() do
      {capped, kept} = Enum.split_with(results, &cap_for(&1, caps))
      log_dropped(capped, caps)
      kept
    else
      _ -> results
    end
  end

  defp log_dropped([], _caps), do: :ok

  defp log_dropped(capped, caps) do
    capped
    |> Enum.map(&TrackerRules.key(&1.indexer))
    |> Enum.uniq()
    |> Enum.each(fn key ->
      {count, limit} = Map.fetch!(caps, key)

      Logger.info(
        "Skipping tracker results: daily grab limit reached (#{count}/#{limit})",
        tracker: key
      )
    end)
  end
end
