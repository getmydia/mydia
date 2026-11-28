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

  @doc "The alerts to show right now, or `[]` when the watcher is not running."
  @spec current(GenServer.server()) :: [Alert.t()]
  def current(server \\ __MODULE__) do
    GenServer.call(server, :current)
  catch
    :exit, _ -> []
  end

  @doc "Subscribes the caller to `{:health_alerts, alerts}` broadcasts."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Mydia.PubSub, @topic)

  @doc "Re-evaluates now, synchronously."
  @spec refresh(GenServer.server()) :: :ok
  def refresh(server \\ __MODULE__), do: GenServer.call(server, :refresh)

  @impl true
  def init(opts) do
    state = %{
      gather: Keyword.get(opts, :gather, &Observations.gather/0),
      now: Keyword.get(opts, :now, &DateTime.utc_now/0),
      interval_ms: Keyword.get(opts, :interval_ms, @interval_ms),
      topic: Keyword.get(opts, :topic, @topic),
      tracker: %{},
      alerts: []
    }

    Phoenix.PubSub.subscribe(Mydia.PubSub, Keyword.get(opts, :built_in_topic, Status.topic()))
    send(self(), :tick)
    {:ok, state}
  end

  @impl true
  def handle_call(:current, _from, state), do: {:reply, state.alerts, state}
  def handle_call(:refresh, _from, state), do: {:reply, :ok, evaluate(state)}

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, state.interval_ms)
    {:noreply, evaluate(state)}
  end

  def handle_info({:built_in_status, _status}, state), do: {:noreply, evaluate(state)}
  def handle_info(_msg, state), do: {:noreply, state}

  defp evaluate(state) do
    {alerts, tracker} = Evaluator.evaluate(state.gather.(), state.tracker, state.now.())

    if keys(alerts) != keys(state.alerts) do
      Phoenix.PubSub.broadcast(Mydia.PubSub, state.topic, {:health_alerts, alerts})
    end

    %{state | alerts: alerts, tracker: tracker}
  end

  defp keys(alerts), do: alerts |> Enum.map(& &1.key) |> Enum.sort()
end
