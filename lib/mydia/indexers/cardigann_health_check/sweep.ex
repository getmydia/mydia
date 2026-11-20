defmodule Mydia.Indexers.CardigannHealthCheck.Sweep do
  @moduledoc """
  The periodic health sweep over every enabled Cardigann definition.

  The sweep stays out of a tracker's way: a definition cooling down after an
  HTTP 429 is skipped and keeps its stored status, one whose real search
  succeeded since the last check (within the last hour) is recorded healthy
  without a request, and a probe takes one of the indexer's per-minute search
  slots like a search. `Mydia.Indexers.CardigannHealthCheck.test_connection/2`
  follows none of these rules.
  """

  require Logger

  alias Mydia.Indexers
  alias Mydia.Indexers.CardigannDefinition
  alias Mydia.Indexers.CardigannHealthCheck
  alias Mydia.Indexers.CardigannHealthCheck.Status
  alias Mydia.Indexers.RateLimiter
  alias Mydia.Repo

  # The sweep runs hourly, so a real search inside the last hour stands in for
  # this round's probe.
  @recent_success_seconds 3_600

  @doc """
  Runs the sweep. Returns `{:ok, results}`, a map of definition_id to
  test_result; skipped definitions are left out.
  """
  @spec check_all_enabled() :: {:ok, map()}
  def check_all_enabled do
    results =
      CardigannDefinition
      |> Repo.all()
      |> Enum.filter(& &1.enabled)
      |> Task.async_stream(fn definition -> {definition.id, sweep(definition)} end,
        timeout: :infinity,
        max_concurrency: 5
      )
      |> Enum.reduce(%{}, fn
        {:ok, {_id, :skipped}}, acc -> acc
        {:ok, {id, {:ok, result}}}, acc -> Map.put(acc, id, result)
        {:ok, {id, {:error, reason}}}, acc -> Map.put(acc, id, %{error: reason})
        _, acc -> acc
      end)

    {:ok, results}
  end

  defp sweep(definition) do
    case sweep_action(definition) do
      :probe -> probe_in_slot(definition)
      {:skip_cooling, until} -> skip(definition, "cooling down until #{Status.clock(until)}")
      :trust_recent_success -> trust_recent_success(definition)
    end
  end

  @spec sweep_action(CardigannDefinition.t()) ::
          :probe | {:skip_cooling, DateTime.t()} | :trust_recent_success
  defp sweep_action(definition) do
    cond do
      until = RateLimiter.cooldown_until(definition.id) -> {:skip_cooling, until}
      success_since_last_check?(definition) -> :trust_recent_success
      true -> :probe
    end
  end

  # Only a search that succeeded after the stored last check counts. A probe
  # records its own success before update_health_status/2 writes
  # last_health_check_at, and that column holds whole seconds, so comparing the
  # success truncated to the second, strictly later, keeps a probe from
  # vouching for the next sweep (a zero-row degraded probe would otherwise read
  # as healthy an hour later).
  defp success_since_last_check?(definition) do
    case RateLimiter.last_success_at(definition.id) do
      nil ->
        false

      at ->
        DateTime.diff(DateTime.utc_now(), at) < @recent_success_seconds and
          later_than_last_check?(DateTime.truncate(at, :second), definition.last_health_check_at)
    end
  end

  defp later_than_last_check?(_at, nil), do: true
  defp later_than_last_check?(at, checked_at), do: DateTime.compare(at, checked_at) == :gt

  defp probe_in_slot(definition) do
    limit = Indexers.cardigann_config(definition).rate_limit

    case RateLimiter.take_search_slot(definition.id, limit) do
      :ok -> CardigannHealthCheck.execute_health_check(definition)
      {:error, :limited, _count} -> skip(definition, "Mydia's per-minute limit reached")
    end
  end

  defp skip(definition, reason) do
    Logger.info("[CardigannHealthCheck] #{definition.name} skipped: #{reason}")
    :skipped
  end

  # A real search that worked is stronger evidence than a probe, so the sweep
  # records it instead of sending one more request.
  defp trust_recent_success(definition) do
    at = RateLimiter.last_success_at(definition.id)

    attrs = %{
      health_status: "healthy",
      last_health_check_at: DateTime.utc_now(),
      consecutive_failures: 0
    }

    case Status.write_health(definition, attrs) do
      # The conditional write skipped a row a search parked meanwhile.
      {:ok, %CardigannDefinition{health_status: "needs_login"}} ->
        {:ok, Status.needs_login_result()}

      _written ->
        {:ok,
         %{
           success: true,
           status: "healthy",
           message: "Healthy: a search succeeded at #{Status.clock(at)}",
           response_time_ms: nil,
           error: nil
         }}
    end
  end
end
