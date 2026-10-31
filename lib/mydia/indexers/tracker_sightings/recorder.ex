defmodule Mydia.Indexers.TrackerSightings.Recorder do
  @moduledoc """
  Buffers tracker sightings from searches and writes them once a minute, so a
  search never waits on the database and a burst of searches costs one write.

  The buffer holds one merged sighting per tracker. `terminate/2` flushes what
  is left, so it sits after the repo in the supervision tree, like
  `Mydia.Indexers.SearchStats.Recorder`. These are hints for the admin page,
  not records: a failed write logs and drops the batch.
  """
  use GenServer, shutdown: 10_000

  alias Mydia.Indexers.TrackerSightings

  @flush_interval_ms 60_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Adds sightings (as built by `TrackerSightings.sightings/2`) to the buffer."
  @spec buffer(%{String.t() => map()}) :: :ok
  def buffer(sightings), do: GenServer.cast(__MODULE__, {:sightings, sightings})

  @doc "Writes the buffer now."
  @spec flush() :: :ok
  def flush, do: GenServer.call(__MODULE__, :flush)

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    {:ok, %{buffer: %{}, timer: nil}}
  end

  @impl true
  def handle_cast({:sightings, sightings}, state) do
    buffer = TrackerSightings.merge_sightings(state.buffer, sightings)
    {:noreply, schedule(%{state | buffer: buffer})}
  end

  @impl true
  def handle_call(:flush, _from, state), do: {:reply, :ok, do_flush(state)}

  @impl true
  def handle_info(:flush, state), do: {:noreply, do_flush(%{state | timer: nil})}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    do_flush(state)
    :ok
  end

  defp schedule(%{timer: nil} = state),
    do: %{state | timer: Process.send_after(self(), :flush, @flush_interval_ms)}

  defp schedule(state), do: state

  defp do_flush(%{buffer: buffer} = state) when map_size(buffer) == 0, do: state

  defp do_flush(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    TrackerSightings.write(state.buffer, :warning)
    %{state | buffer: %{}, timer: nil}
  end
end
