defmodule Mydia.Jobs.StatusTracker do
  @moduledoc """
  Decides which executing jobs the sidebar's running-jobs card shows.

  Most background jobs finish in milliseconds. Showing each one made the card
  appear and vanish faster than it could be read, so this process filters them:

    * a job is shown only once it has been running for `@show_after_ms`
    * once anything is shown, the card stays up for at least `@min_visible_ms`,
      holding the last list if every job ends sooner

  `Mydia.Jobs.Broadcaster` feeds it from Oban telemetry. It broadcasts
  `{:jobs_status_changed, jobs}` on `Mydia.Jobs.Broadcaster.topic/0`, and only
  when the shown list changes, so short jobs cost subscribers nothing.

  The tracker starts empty and learns jobs only from telemetry. It is not
  seeded from `oban_jobs`: it starts before `Mydia.Application` resets stale
  jobs, so at boot every `executing` row is a leftover of the previous run.
  If this process restarts, jobs already in flight go unreported until they end.
  On start it broadcasts an empty list, so pages showing a job from before a
  restart clear it.

  A stop event can be lost when a queue is killed past its shutdown grace
  period. While any job is tracked, the tracker checks the database every
  `@reconcile_ms` and forgets jobs that are no longer `executing`.
  """
  use GenServer

  require Logger

  alias Mydia.Jobs
  alias Mydia.Jobs.Broadcaster

  @show_after_ms 2_000
  @min_visible_ms 3_000
  @reconcile_ms 60_000

  @visible_fields [:id, :worker, :worker_name, :attempted_at]

  defstruct jobs: %{},
            visible: [],
            shown_at: nil,
            timer: nil,
            reconcile_timer: nil,
            show_after_ms: @show_after_ms,
            min_visible_ms: @min_visible_ms,
            reconcile_ms: @reconcile_ms

  @doc """
  Starts the tracker.

  `:name` defaults to this module. `:show_after_ms`, `:min_visible_ms` and
  `:reconcile_ms` exist so tests can run in milliseconds.
  """
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Records that a job began executing. Safe to call when the tracker is down."
  def job_started(server \\ __MODULE__, %Oban.Job{id: id, worker: worker}) do
    GenServer.cast(server, {:started, id, worker})
  end

  @doc "Records that a job stopped, however it ended. Safe to call when the tracker is down."
  def job_finished(server \\ __MODULE__, %Oban.Job{id: id}) do
    GenServer.cast(server, {:finished, id})
  end

  @doc """
  The jobs the sidebar should show right now, oldest first.

  Returns `[]` when the tracker is not running or does not answer in time, so
  a page mount never fails on it.
  """
  def visible_jobs(server \\ __MODULE__) do
    GenServer.call(server, :visible_jobs, 1_000)
  catch
    :exit, _reason -> []
  end

  @impl true
  def init(opts) do
    state =
      struct!(__MODULE__, Keyword.take(opts, [:show_after_ms, :min_visible_ms, :reconcile_ms]))

    {:ok, state, {:continue, :announce}}
  end

  # A restart forgets what was shown. Pages that were showing a job would keep
  # it until the next change, so say that nothing is shown now.
  @impl true
  def handle_continue(:announce, state) do
    broadcast([])
    {:noreply, state}
  end

  @impl true
  def handle_call(:visible_jobs, _from, state) do
    {:reply, state.visible, state}
  end

  @impl true
  def handle_cast({:started, id, worker}, state) do
    job = %{
      id: id,
      worker: worker,
      worker_name: Jobs.worker_display_name_from_string(worker),
      attempted_at: DateTime.utc_now(),
      started_at: now()
    }

    state = %{state | jobs: Map.put(state.jobs, id, job)}
    {:noreply, state |> ensure_reconcile() |> recompute()}
  end

  def handle_cast({:finished, id}, state) do
    {:noreply, recompute(%{state | jobs: Map.delete(state.jobs, id)})}
  end

  @impl true
  def handle_info(:tick, state) do
    {:noreply, recompute(state)}
  end

  def handle_info(:reconcile, state) do
    state = %{state | reconcile_timer: nil}
    {:noreply, state |> drop_finished() |> ensure_reconcile() |> recompute()}
  end

  # Recomputing is idempotent, so a :tick that arrives after its timer was
  # replaced does no harm.
  defp recompute(state) do
    now = now()

    eligible =
      state.jobs
      |> Map.values()
      |> Enum.filter(&(now - &1.started_at >= state.show_after_ms))
      |> Enum.sort_by(&{&1.started_at, &1.id})
      |> Enum.map(&Map.take(&1, @visible_fields))

    state
    |> apply_visible(eligible, now)
    |> schedule_tick(now)
  end

  defp apply_visible(state, eligible, now) do
    cond do
      eligible == state.visible ->
        state

      eligible == [] and holding?(state, now) ->
        state

      true ->
        broadcast(eligible)
        %{state | visible: eligible, shown_at: shown_at(state, eligible, now)}
    end
  end

  defp broadcast(jobs) do
    Phoenix.PubSub.broadcast(Mydia.PubSub, Broadcaster.topic(), {:jobs_status_changed, jobs})
  end

  defp holding?(%{shown_at: nil}, _now), do: false
  defp holding?(state, now), do: now - state.shown_at < state.min_visible_ms

  defp shown_at(_state, [], _now), do: nil
  defp shown_at(%{visible: []}, _eligible, now), do: now
  defp shown_at(state, _eligible, _now), do: state.shown_at

  # One timer for the next moment the shown list can change: a tracked job
  # reaching the delay, or the hold running out.
  defp schedule_tick(state, now) do
    if state.timer, do: Process.cancel_timer(state.timer)

    until_eligible =
      state.jobs
      |> Map.values()
      |> Enum.map(&(state.show_after_ms - (now - &1.started_at)))
      |> Enum.filter(&(&1 > 0))

    until_hold_ends =
      if holding?(state, now), do: [state.min_visible_ms - (now - state.shown_at)], else: []

    case Enum.min(until_eligible ++ until_hold_ends, fn -> nil end) do
      nil -> %{state | timer: nil}
      delay -> %{state | timer: Process.send_after(self(), :tick, delay)}
    end
  end

  defp ensure_reconcile(%{reconcile_timer: nil, jobs: jobs} = state) when map_size(jobs) > 0 do
    %{state | reconcile_timer: Process.send_after(self(), :reconcile, state.reconcile_ms)}
  end

  defp ensure_reconcile(state), do: state

  defp drop_finished(%{jobs: jobs} = state) when map_size(jobs) == 0, do: state

  defp drop_finished(state) do
    executing = MapSet.new(Jobs.list_executing_jobs(), & &1.id)
    %{state | jobs: Map.filter(state.jobs, fn {id, _job} -> MapSet.member?(executing, id) end)}
  rescue
    error ->
      Logger.warning("Job status reconcile failed: #{Exception.message(error)}")
      state
  end

  defp now, do: System.monotonic_time(:millisecond)
end
