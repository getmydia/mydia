defmodule Mydia.Indexers.SearchGate do
  @moduledoc """
  The gate in front of one indexer's search, keyed by its id (never its name).

  In order: a cooldown after HTTP 429 sends nothing, then Mydia's per-minute
  slot, then the tracker's daily search cap (`Mydia.Indexers.TrackerLimits`),
  then the search, whose outcome clears or starts a cooldown. A search refused
  by a cooldown or the per-minute limit takes no daily slot. Every
  `:rate_limited` error leaving here carries `details.source`.

  See `lib/mydia/indexers/README.md`, "Rate limits and cooldown".
  """

  alias Mydia.Indexers.Adapter
  alias Mydia.Indexers.{RateLimiter, TrackerLimits}

  require Logger

  @doc """
  Runs `search_fun` (one indexer's search) for `config` unless the indexer is
  cooling down, out of per-minute slots or at its tracker's daily cap.
  `config` needs `:id` and `:rate_limit`; `:name` labels logs and picks the
  tracker rule.
  """
  @spec run(map(), (-> result)) :: result | {:error, Adapter.Error.t()} when result: term()
  def run(%{id: id} = config, search_fun) do
    name = Map.get(config, :name)

    with :ok <- check_cooldown(id, name),
         :ok <- take_search_slot(id, name, config.rate_limit) do
      config
      |> TrackerLimits.guard_query(search_fun)
      |> record_outcome(id, name)
    end
  end

  defp check_cooldown(id, name) do
    case RateLimiter.cooldown_until(id) do
      nil ->
        :ok

      until ->
        Logger.info("Skipping #{name}: cooling down after HTTP 429 until #{clock(until)}")

        {:error,
         Adapter.Error.rate_limited("Cooling down after HTTP 429 until #{clock(until)}", %{
           source: :cooldown,
           until: until
         })}
    end
  end

  defp take_search_slot(id, name, rate_limit) do
    case RateLimiter.take_search_slot(id, rate_limit) do
      :ok ->
        :ok

      {:error, :limited, _count} ->
        reason = "Mydia's limit of #{rate_limit} searches/minute reached"
        Logger.info("Skipping #{name}: #{reason}")

        {:error,
         Adapter.Error.rate_limited(reason, %{
           source: :local_limit,
           retry_after: :timer.minutes(1)
         })}
    end
  end

  defp record_outcome({:ok, _} = result, id, _name) do
    RateLimiter.record_success(id)
    result
  end

  defp record_outcome(
         {:error, %Adapter.Error{type: :rate_limited, details: details} = error},
         id,
         name
       ) do
    details = details || %{}

    if Map.has_key?(details, :source) do
      {:error, error}
    else
      retry_after = Map.get(details, :retry_after)
      until = RateLimiter.record_rate_limited(id, retry_after)

      Logger.warning("#{name} answered HTTP 429; pausing it until #{clock(until)}",
        retry_after_ms: retry_after
      )

      {:error,
       %{
         error
         | message: "Tracker answered HTTP 429; paused until #{clock(until)}",
           details: Map.merge(details, %{source: :tracker, until: until})
       }}
    end
  end

  defp record_outcome(result, _id, _name), do: result

  @doc """
  Labels an untagged rate-limit error `source: :tracker` without starting a
  cooldown (Prowlarr runs its own backoff for the trackers behind it).
  """
  @spec tag_tracker_rate_limit(result) :: result when result: term()
  def tag_tracker_rate_limit(
        {:error, %Adapter.Error{type: :rate_limited, details: details} = error}
      ) do
    details = details || %{}

    if Map.has_key?(details, :source),
      do: {:error, error},
      else: {:error, %{error | details: Map.put(details, :source, :tracker)}}
  end

  def tag_tracker_rate_limit(result), do: result

  @doc """
  True when Mydia chose not to search (cooldown, its own per-minute limit, a
  daily cap); the gate or TrackerLimits already logged why at info level.
  """
  @spec deliberate_skip?(term()) :: boolean()
  def deliberate_skip?(%Adapter.Error{type: :rate_limited, details: %{source: source}}),
    do: source in [:cooldown, :local_limit, :daily_cap]

  def deliberate_skip?(_error), do: false

  @doc """
  The outcome a failed search records in search stats. A deliberate skip sent
  nothing, so it is recorded apart from a tracker 429 and kept out of attempts
  and success (`Mydia.Indexers.SearchStats.Summary`).
  """
  @spec outcome(Adapter.Error.t()) :: atom()
  def outcome(%Adapter.Error{type: :rate_limited, details: %{source: :cooldown}}),
    do: :skipped_cooldown

  def outcome(%Adapter.Error{type: :rate_limited, details: %{source: :local_limit}}),
    do: :skipped_local_limit

  def outcome(%Adapter.Error{type: :rate_limited, details: %{source: :daily_cap}}),
    do: :skipped_daily_cap

  def outcome(%Adapter.Error{type: type}), do: type

  @doc """
  True when a `Mydia.Indexers.search_all/2` result found nothing only because
  every indexer searched was rate-limited (a 429, a cooldown, Mydia's
  per-minute limit or a daily cap). Such a search says nothing about whether
  releases exist.
  """
  @spec deferred_by_rate_limits?(map()) :: boolean()
  def deferred_by_rate_limits?(%{
        results: [],
        indexers_searched: searched,
        indexer_errors: errors
      })
      when searched > 0 and length(errors) == searched,
      do: Enum.all?(errors, &(&1.error_type == :rate_limited))

  def deferred_by_rate_limits?(_result), do: false

  # Hours and minutes in UTC, like the other indexer logs.
  defp clock(%DateTime{} = at), do: Calendar.strftime(at, "%H:%M")
end
