defmodule Mydia.Events.Writer do
  @moduledoc """
  Single owner of asynchronous event inserts.

  Every `Mydia.Events.create_event_async/1` call outside the SQL sandbox routes
  here. The writer buffers validated events and flushes them as one
  `Repo.insert_all/2`, so a burst costs one write transaction and one pool
  checkout instead of one of each per event.

  This replaced a `Task` per event. A bulk operation such as
  `Mydia.Media.update_media_items_monitored/3` fires one event per item from
  inside a transaction that already holds the SQLite write lock, so those tasks
  contended for a lock their own caller was holding and surfaced
  `Exqlite.Error{message: "Database busy"}`. See issue #283.

  Events are an activity log, not a durable record. The buffer is bounded and
  drops oldest on overflow, and a failed insert is logged and dropped rather
  than retried, because retrying reintroduces the contention this module exists
  to remove.
  """
  use GenServer

  require Logger

  alias Mydia.Events
  alias Mydia.Events.Event
  alias Mydia.Repo

  @max_batch 100
  @flush_interval_ms 200
  @max_buffer 5_000

  ## Client

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    # `name: nil` starts an unregistered writer. GenServer rejects a literal
    # `name: nil`, so the option is omitted entirely in that case. Tests use it
    # to run their own writer alongside the supervised one.
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Validates `attrs` and queues the resulting event for insertion.

  Always returns `:ok`. Validation runs in the calling process so an invalid
  changeset is attributed to the caller and never occupies buffer space. An
  invalid changeset is logged and dropped, matching the fire-and-forget
  contract of `Mydia.Events.create_event_async/1`.
  """
  @spec enqueue(map(), GenServer.server()) :: :ok
  def enqueue(attrs, server \\ __MODULE__) do
    case build(attrs) do
      {:ok, event} ->
        GenServer.cast(server, {:event, event})

      {:error, changeset} ->
        Logger.error("Failed to create event asynchronously: #{inspect(changeset.errors)}")
        :ok
    end
  end

  @doc """
  Flushes the buffer synchronously, returning after the insert and broadcasts.
  """
  @spec flush(GenServer.server()) :: :ok
  def flush(server \\ __MODULE__), do: GenServer.call(server, :flush)

  # Repo.insert_all/2 autogenerates neither the primary key nor the timestamp,
  # so both are filled here. :utc_datetime is second precision.
  defp build(attrs) do
    %Event{}
    |> Event.changeset(attrs)
    |> Ecto.Changeset.apply_action(:insert)
    |> case do
      {:ok, event} ->
        {:ok,
         %{
           event
           | id: Ecto.UUID.generate(),
             inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
         }}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  ## Server

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       buffer: :queue.new(),
       size: 0,
       dropped: 0,
       timer: nil,
       max_batch: Keyword.get(opts, :max_batch, @max_batch),
       flush_interval_ms: Keyword.get(opts, :flush_interval_ms, @flush_interval_ms),
       max_buffer: Keyword.get(opts, :max_buffer, @max_buffer)
     }}
  end

  @impl true
  def handle_cast({:event, event}, state) do
    {:noreply, state |> buffer(event) |> maybe_flush()}
  end

  @impl true
  def handle_call(:flush, _from, state), do: {:reply, :ok, do_flush(state)}

  @impl true
  def handle_info(:flush, state), do: {:noreply, do_flush(state)}

  @impl true
  def terminate(_reason, state) do
    do_flush(state)
    :ok
  end

  ## Internals

  defp buffer(%{size: size, max_buffer: max} = state, event) when size >= max do
    # :queue is FIFO, so the front is the oldest event.
    {_oldest, queue} = :queue.out(state.buffer)
    %{state | buffer: :queue.in(event, queue), dropped: state.dropped + 1}
  end

  defp buffer(state, event) do
    %{state | buffer: :queue.in(event, state.buffer), size: state.size + 1}
  end

  defp maybe_flush(%{size: size, max_batch: max} = state) when size >= max, do: do_flush(state)
  defp maybe_flush(state), do: schedule_flush(state)

  defp schedule_flush(%{timer: nil, size: size} = state) when size > 0 do
    %{state | timer: Process.send_after(self(), :flush, state.flush_interval_ms)}
  end

  defp schedule_flush(state), do: state

  defp do_flush(%{size: 0} = state), do: cancel_timer(state)

  defp do_flush(state) do
    events = :queue.to_list(state.buffer)
    log_dropped(state.dropped)

    case insert_batch(events) do
      :ok -> Enum.each(events, &Events.broadcast_event/1)
      :error -> :ok
    end

    %{cancel_timer(state) | buffer: :queue.new(), size: 0, dropped: 0}
  end

  defp insert_batch(events) do
    Repo.insert_all(Event, Enum.map(events, &row/1))
    :ok
  rescue
    error ->
      Logger.error(
        "Events.Writer dropped #{length(events)} event(s): #{Exception.message(error)}"
      )

      :error
  end

  defp row(%Event{} = event) do
    %{
      id: event.id,
      category: event.category,
      type: event.type,
      actor_type: event.actor_type,
      actor_id: event.actor_id,
      resource_type: event.resource_type,
      resource_id: event.resource_id,
      severity: event.severity,
      metadata: event.metadata,
      inserted_at: event.inserted_at
    }
  end

  defp log_dropped(0), do: :ok

  defp log_dropped(count) do
    Logger.warning("Events.Writer buffer full, dropped #{count} event(s)")
  end

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(%{timer: ref} = state) do
    Process.cancel_timer(ref)
    %{state | timer: nil}
  end
end
