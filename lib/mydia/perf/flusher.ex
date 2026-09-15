defmodule Mydia.Perf.Flusher do
  @moduledoc """
  Persists Peep's distributions as hourly `perf_rollups` rows.

  Every `flush_interval_ms`, aligned to the wall clock, it takes a Peep
  snapshot, subtracts the snapshot from the start of the current hour, and
  upserts the result as that hour's rows, replacing what the previous flush
  wrote. The first flush in a new hour closes the old hour, re-bases, and
  deletes rows older than `retention_days`. Events between the last flush of an
  hour and the boundary count toward the old hour.

  Rows carry this boot's `boot_id`, so a restart writes new rows for the hour
  instead of overwriting or double-counting the previous boot's. `terminate/2`
  flushes once more, so a deploy loses nothing and a crash loses at most one
  interval.

  A failed write logs a warning and changes no state. Peep's values are
  cumulative, so the next successful flush writes correct totals.
  """

  use GenServer

  require Logger

  import Ecto.Query

  alias Mydia.Perf.Rollup
  alias Mydia.Perf.Snapshot
  alias Mydia.Repo

  @chunk_size 500
  @replace [:count, :sum_us, :buckets, :updated_at]
  @conflict_target [:hour, :boot_id, :metric, :tags]

  @doc """
  Starts the flusher.

  Options: `:name` (default `#{inspect(__MODULE__)}`, `nil` leaves it
  unregistered), `:peep` (default `Mydia.Perf.Peep`), `:clock` (a zero-arity
  function returning a `DateTime`), `:interval_ms`, `:retention_days`, and
  `:schedule?` (default `true`; tests pass `false` and call `flush/1`).
  """
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Flushes now."
  @spec flush(GenServer.server()) :: :ok | {:error, term()}
  def flush(server \\ __MODULE__), do: GenServer.call(server, :flush)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    config = Application.get_env(:mydia, Mydia.Perf, [])
    clock = Keyword.get(opts, :clock, &DateTime.utc_now/0)

    state = %{
      peep: Keyword.get(opts, :peep, Mydia.Perf.Peep),
      clock: clock,
      boot_id: Ecto.UUID.generate(),
      hour: Rollup.hour_of(clock.()),
      baseline: %{},
      interval_ms:
        Keyword.get(opts, :interval_ms, Keyword.get(config, :flush_interval_ms, 300_000)),
      retention_days:
        Keyword.get(opts, :retention_days, Keyword.get(config, :retention_days, 14)),
      schedule?: Keyword.get(opts, :schedule?, true)
    }

    {:ok, schedule(state)}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    {result, state} = flush_and_roll_over(state)
    {:reply, result, state}
  end

  @impl true
  def handle_info(:tick, state) do
    {_result, state} = flush_and_roll_over(state)
    {:noreply, schedule(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    write(state, snapshot(state))
    :ok
  end

  defp flush_and_roll_over(state) do
    current = snapshot(state)

    case write(state, current) do
      :ok -> {:ok, roll_over(state, current)}
      {:error, _reason} = error -> {error, state}
    end
  end

  # A Peep killed without running terminate/2 leaves its persistent term
  # pointing at a deleted ETS table. The supervisor restarts this process with
  # it, so an empty snapshot until then is enough.
  defp snapshot(state) do
    state.peep |> Peep.get_all_metrics() |> Snapshot.normalize()
  rescue
    ArgumentError -> %{}
  end

  defp write(state, current) do
    now = DateTime.truncate(state.clock.(), :second)

    entries =
      for delta <- Snapshot.deltas(current, state.baseline) do
        %{
          id: Ecto.UUID.generate(),
          hour: state.hour,
          boot_id: state.boot_id,
          metric: delta.metric,
          tags: delta.tags,
          count: delta.count,
          sum_us: delta.sum_us,
          buckets: Jason.encode!(delta.buckets),
          inserted_at: now,
          updated_at: now
        }
      end

    upsert(entries)
  end

  defp upsert([]), do: :ok

  defp upsert(entries) do
    result =
      Repo.transaction(fn ->
        entries
        |> Enum.chunk_every(@chunk_size)
        |> Enum.each(fn chunk ->
          Repo.insert_all(Rollup, chunk,
            on_conflict: {:replace, @replace},
            conflict_target: @conflict_target
          )
        end)
      end)

    case result do
      {:ok, _} -> :ok
      {:error, reason} -> warn(reason)
    end
  rescue
    exception -> warn(exception)
  end

  defp roll_over(state, current) do
    hour = Rollup.hour_of(state.clock.())

    if DateTime.compare(hour, state.hour) == :eq do
      state
    else
      prune(state, hour)
      %{state | hour: hour, baseline: current}
    end
  end

  defp prune(state, hour) do
    cutoff = DateTime.add(hour, -state.retention_days * 86_400, :second)
    Repo.delete_all(from r in Rollup, where: r.hour < ^cutoff)
  rescue
    exception -> warn(exception)
  end

  defp warn(reason) do
    Logger.warning("Performance metrics flush failed: #{inspect(reason)}")
    {:error, reason}
  end

  defp schedule(%{schedule?: false} = state), do: state

  defp schedule(state) do
    now_ms = DateTime.to_unix(state.clock.(), :millisecond)
    Process.send_after(self(), :tick, state.interval_ms - rem(now_ms, state.interval_ms))
    state
  end
end
