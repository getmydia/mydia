defmodule Mydia.Indexers.SearchStats.Recorder do
  @moduledoc """
  Writes `Mydia.Indexers.SearchStats.Telemetry` events to
  `indexer_search_events`.

  Attaches its own telemetry handler in `init/1`, so events are recorded
  exactly while this process runs. The handler runs in the emitting process
  (a search task) and only casts, so a search never waits on the database.
  Events are buffered and written with one `Repo.insert_all/3` every 30
  seconds or every 200 events, the same reasoning as `Mydia.Events.Writer`:
  one SQLite write transaction per burst instead of one per indexer.

  These are metrics, not records. A failed insert logs a warning and drops
  the batch; a full buffer drops new events. Under the SQL sandbox `record/2`
  inserts synchronously in the caller, as `Mydia.Events.create_event_async/1`
  does, so tests see their own rows.

  Returns `:ignore` under `MYDIA_CLI_MODE=true`.
  """
  # terminate/2 flushes through Repo.insert_all, which can wait on the SQLite
  # write lock; see Mydia.Events.Writer for why 10 seconds.
  use GenServer, shutdown: 10_000

  require Logger

  alias Mydia.Indexers.SearchStats.{Event, Telemetry}
  alias Mydia.Repo

  @flush_interval_ms 30_000
  @max_batch 200
  @max_buffer 5_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc "Records one event: inserted now under the SQL sandbox, otherwise buffered."
  @spec record(Event.t(), GenServer.server()) :: :ok
  def record(%Event{} = event, server \\ __MODULE__) do
    if sandbox_pool?() do
      insert([event], :debug)
      :ok
    else
      buffer(event, server)
    end
  end

  @doc false
  @spec buffer(Event.t(), GenServer.server()) :: :ok
  def buffer(%Event{} = event, server), do: GenServer.cast(server, {:event, event})

  @doc "Writes the buffer now."
  @spec flush(GenServer.server()) :: :ok
  def flush(server \\ __MODULE__), do: GenServer.call(server, :flush)

  @doc false
  def handle_telemetry(_event, measurements, metadata, %{server: server}) do
    measurements |> Event.from_telemetry(metadata) |> record(server)
  rescue
    # :telemetry detaches a handler that raises; a malformed event must not
    # switch recording off for the rest of the node's life.
    error -> Logger.debug("SearchStats.Recorder skipped an event: #{Exception.message(error)}")
  end

  @impl true
  def init(opts) do
    if System.get_env("MYDIA_CLI_MODE") == "true" do
      :ignore
    else
      Process.flag(:trap_exit, true)

      if Keyword.get(opts, :attach, true) do
        :telemetry.attach(
          {__MODULE__, self()},
          Telemetry.event(),
          &__MODULE__.handle_telemetry/4,
          %{server: self()}
        )
      end

      {:ok,
       %{
         buffer: [],
         size: 0,
         dropped: 0,
         timer: nil,
         flush_interval_ms: Keyword.get(opts, :flush_interval_ms, @flush_interval_ms),
         max_batch: Keyword.get(opts, :max_batch, @max_batch),
         max_buffer: Keyword.get(opts, :max_buffer, @max_buffer)
       }}
    end
  end

  @impl true
  def handle_cast({:event, _event}, %{size: size, max_buffer: max} = state) when size >= max do
    {:noreply, %{state | dropped: state.dropped + 1}}
  end

  def handle_cast({:event, event}, state) do
    state = %{state | buffer: [event | state.buffer], size: state.size + 1}

    if state.size >= state.max_batch,
      do: {:noreply, do_flush(state)},
      else: {:noreply, schedule_flush(state)}
  end

  @impl true
  def handle_call(:flush, _from, state), do: {:reply, :ok, do_flush(state)}

  @impl true
  def handle_info(:flush, state), do: {:noreply, do_flush(%{state | timer: nil})}

  @impl true
  def terminate(_reason, state) do
    :telemetry.detach({__MODULE__, self()})
    do_flush(state)
    :ok
  end

  defp schedule_flush(%{timer: nil} = state),
    do: %{state | timer: Process.send_after(self(), :flush, state.flush_interval_ms)}

  defp schedule_flush(state), do: state

  defp do_flush(state) do
    if state.timer, do: Process.cancel_timer(state.timer)

    if state.dropped > 0,
      do: Logger.warning("SearchStats.Recorder buffer full, dropped #{state.dropped} event(s)")

    if state.size > 0, do: insert(Enum.reverse(state.buffer), :warning)

    %{state | buffer: [], size: 0, dropped: 0, timer: nil}
  end

  defp insert(events, failure_level) do
    Repo.insert_all(Event, Enum.map(events, &Event.row/1))
    :ok
  rescue
    error ->
      Logger.log(
        failure_level,
        "SearchStats.Recorder dropped #{length(events)} indexer search event(s): " <>
          Exception.message(error)
      )

      :error
  end

  defp sandbox_pool?, do: Repo.config()[:pool] == Ecto.Adapters.SQL.Sandbox
end
