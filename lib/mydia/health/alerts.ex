defmodule Mydia.Health.Alerts do
  @moduledoc """
  Watches for fatal conditions and keeps the current list of alerts admins
  should see in the sidebar and on the home dashboard.

  Every minute, and whenever the built-in torrent client's status changes, it
  gathers observations (`Mydia.Health.Alerts.Observations`) and runs them
  through `Mydia.Health.Alerts.Evaluator`, which applies the 10-minute grace
  period and the 5-minute clear period. When the set of alert keys changes it
  broadcasts `{:health_alerts, alerts}` on `topic/0`.

  Started only when `:start_health_monitors` is on, like `ClientHealth`;
  `current/0` returns `[]` when it is not running.
  """

  use GenServer

  require Logger

  alias Mydia.Downloads.BuiltIn.Status
  alias Mydia.Health.Alert
  alias Mydia.Health.Alerts.{Evaluator, Observations}

  @topic "health:alerts"
  @interval_ms 60_000

  def topic, do: @topic

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc """
  The alerts to show right now, or `[]` when the watcher is not running.

  Read from `:persistent_term`, never from the process, so a page mount cannot
  wait on a slow gather (a busy database, or a library root on a hung network
  mount). The term is rewritten only when the alert list changes.
  """
  @spec current(atom()) :: [Alert.t()]
  def current(name \\ __MODULE__), do: :persistent_term.get({__MODULE__, name}, [])

  @doc "Subscribes the caller to `{:health_alerts, alerts}` broadcasts."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Mydia.PubSub, @topic)

  @doc """
  Gathers and re-evaluates now, synchronously, in the watcher's own process.
  For tests and diagnostics; the timer runs gathers in a separate task.
  """
  @spec refresh(atom()) :: :ok
  def refresh(name \\ __MODULE__), do: GenServer.call(name, :refresh)

  @impl true
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    state = %{
      name: name,
      gather: Keyword.get(opts, :gather, &Observations.gather/0),
      now: Keyword.get(opts, :now, &DateTime.utc_now/0),
      interval_ms: Keyword.get(opts, :interval_ms, @interval_ms),
      topic: Keyword.get(opts, :topic, @topic),
      task_supervisor: Keyword.get(opts, :task_supervisor, Mydia.TaskSupervisor),
      task: nil,
      tracker: %{},
      alerts: []
    }

    :persistent_term.put({__MODULE__, name}, [])
    Phoenix.PubSub.subscribe(Mydia.PubSub, Keyword.get(opts, :built_in_topic, Status.topic()))
    # The first gather waits one interval: nothing can alert before 10 minutes
    # anyway, and boot is when the health caches are still filling.
    Process.send_after(self(), :tick, state.interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_call(:refresh, _from, state),
    do: {:reply, :ok, apply_observations(state, state.gather.())}

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, state.interval_ms)
    {:noreply, start_gather(state)}
  end

  def handle_info({:built_in_status, _status}, state), do: {:noreply, start_gather(state)}

  def handle_info({ref, observations}, %{task: ref} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, apply_observations(%{state | task: nil}, observations)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: ref} = state) do
    Logger.warning("Health alerts gather failed: #{inspect(reason)}")
    {:noreply, %{state | task: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # One gather at a time: while one is still running (a stat blocked on a hung
  # mount), later ticks are skipped rather than piling up blocked tasks. The
  # task is not linked, so a gather that raises cannot take the watcher down.
  defp start_gather(%{task: nil} = state) do
    task = Task.Supervisor.async_nolink(state.task_supervisor, state.gather)
    %{state | task: task.ref}
  end

  defp start_gather(state), do: state

  defp apply_observations(state, observations) do
    {alerts, tracker} = Evaluator.evaluate(observations, state.tracker, state.now.())

    if alerts != state.alerts do
      :persistent_term.put({__MODULE__, state.name}, alerts)
    end

    if keys(alerts) != keys(state.alerts) do
      Phoenix.PubSub.broadcast(Mydia.PubSub, state.topic, {:health_alerts, alerts})
    end

    %{state | alerts: alerts, tracker: tracker}
  end

  defp keys(alerts), do: alerts |> Enum.map(& &1.key) |> Enum.sort()
end
