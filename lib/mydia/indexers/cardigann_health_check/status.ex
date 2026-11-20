defmodule Mydia.Indexers.CardigannHealthCheck.Status do
  @moduledoc """
  The health status a Cardigann probe writes to its definition, and the
  result maps shared by the probe paths of `Mydia.Indexers.CardigannHealthCheck`.
  """

  import Ecto.Query, only: [from: 2]

  alias Mydia.Indexers.Adapter.Error
  alias Mydia.Indexers.CardigannDefinition
  alias Mydia.Indexers.RateLimiter
  alias Mydia.Repo

  @doc """
  Writes `result` to `definition`: its status, the check time, and the
  consecutive-failure count (reset by a success, left alone by a 429).
  """
  @spec update_health_status(CardigannDefinition.t(), map()) ::
          {:ok, CardigannDefinition.t()} | {:error, Ecto.Changeset.t()}
  def update_health_status(definition, result) do
    write_health(definition, health_attrs(definition, result, DateTime.utc_now()))
  end

  # A 429 leaves consecutive_failures alone: the tracker is throttling Mydia,
  # not broken. Writing "degraded" over "unhealthy" is deliberate: the tracker
  # answered.
  defp health_attrs(_definition, %{rate_limited: true} = result, now),
    do: %{health_status: result.status, last_health_check_at: now}

  defp health_attrs(_definition, %{success: true} = result, now) do
    %{
      health_status: result.status,
      last_health_check_at: now,
      last_successful_query_at: now,
      consecutive_failures: 0
    }
  end

  defp health_attrs(definition, result, now) do
    %{
      health_status: result.status,
      last_health_check_at: now,
      consecutive_failures: (definition.consecutive_failures || 0) + 1
    }
  end

  @doc """
  Writes `attrs` unless a search parked the row in needs_login meanwhile, and
  returns the row as stored.
  """
  @spec write_health(CardigannDefinition.t(), map()) ::
          {:ok, CardigannDefinition.t()} | {:error, Ecto.Changeset.t()}
  def write_health(definition, attrs) do
    changeset = CardigannDefinition.health_check_changeset(definition, attrs)

    # The probe takes seconds and works on a struct loaded before it started. A
    # search may have set needs_login meanwhile, and only a login clears it, so
    # the write is conditional on the row's current status, not the struct's.
    # Every attr is written, not just changeset.changes: the changes are a diff
    # against that stale struct, and are empty when a check in the same second
    # repeats its values, which update_all rejects.
    with true <- changeset.valid?,
         {1, _} <-
           Repo.update_all(
             from(d in CardigannDefinition,
               where: d.id == ^definition.id and d.health_status != "needs_login"
             ),
             set:
               changeset
               |> Ecto.Changeset.apply_changes()
               |> Map.take(Map.keys(attrs))
               |> Map.to_list()
           ) do
      {:ok, Repo.get!(CardigannDefinition, definition.id)}
    else
      false -> {:error, changeset}
      {0, _} -> {:ok, Repo.get!(CardigannDefinition, definition.id)}
    end
  end

  @doc "The status a probe that succeeded or failed in `response_time` ms earns."
  @spec determine_health_status(CardigannDefinition.t(), boolean(), non_neg_integer()) ::
          String.t()
  def determine_health_status(definition, success, response_time) do
    cond do
      success && response_time < 5_000 ->
        "healthy"

      success && response_time < 15_000 ->
        "degraded"

      success ->
        "degraded"

      definition.consecutive_failures >= 3 ->
        "unhealthy"

      true ->
        "degraded"
    end
  end

  @doc """
  The result for a definition waiting on a login. Nothing is persisted:
  needs_login is cleared only by a real login, so a check must neither
  overwrite it nor count as a failure.
  """
  @spec needs_login_result() :: map()
  def needs_login_result do
    %{
      success: false,
      status: "needs_login",
      message: "Needs login",
      response_time_ms: nil,
      error: nil
    }
  end

  @doc """
  The result for a probe the tracker answered with HTTP 429. A tracker
  throttling Mydia is not broken, so the 429 cools the indexer down (the same
  cooldown a search sees) without counting as a failure; see
  `update_health_status/2`.
  """
  @spec rate_limited_result(CardigannDefinition.t(), Error.t(), non_neg_integer()) :: map()
  def rate_limited_result(definition, %Error{} = error, elapsed) do
    until = RateLimiter.record_rate_limited(definition.id, (error.details || %{})[:retry_after])

    %{
      success: false,
      rate_limited: true,
      status: "degraded",
      message: "Tracker answered HTTP 429; paused until #{clock(until)}",
      response_time_ms: elapsed,
      error: error.message
    }
  end

  @doc "Records a probe search that worked as the definition's last success."
  @spec note_success(CardigannDefinition.t(), term()) :: :ok
  def note_success(definition, {:ok, _results}), do: RateLimiter.record_success(definition.id)

  def note_success(definition, {:ok, _count, _served_by}),
    do: RateLimiter.record_success(definition.id)

  def note_success(_definition, _outcome), do: :ok

  @doc "Hours and minutes in UTC, like the other indexer logs."
  @spec clock(DateTime.t()) :: String.t()
  def clock(%DateTime{} = at), do: Calendar.strftime(at, "%H:%M")
end
