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

  Events are an activity log, not a durable record. Total pending events are
  bounded by two limits stacked in front of each other. The mailbox limit
  caps messages waiting in the writer's own inbox, which matters because
  `Repo.insert_all/2` can block the writer for the SQLite busy_timeout under
  write contention while callers keep casting. The buffer limit caps
  validated events waiting to be flushed once the writer has caught up on its
  inbox. On overflow the buffer drops the oldest event, since the writer owns
  the buffer and can pop from either end; the mailbox limit instead drops the
  newest event, the one a caller is trying to enqueue right now, because a
  caller has no way to reach into another process's mailbox and evict an
  older message. A failed insert is logged and dropped rather than retried,
  because retrying reintroduces the contention this module exists to remove.

  On shutdown, `terminate/2` makes a best-effort flush of the buffer through
  `Repo.insert_all/2`. A shutdown that lands during heavy write contention can
  still exceed the shutdown timeout and drop the buffer, which is consistent
  with the activity-log contract above: these events are not a durable
  record.
  """
  # terminate/2 flushes through Repo.insert_all, which can block on the
  # SQLite write lock, so the default 5 second shutdown timeout is too tight.
  # 30 seconds would match busy_timeout exactly, but that would hold a
  # container restart hostage well past the typical grace period for what is
  # an activity log, so 10 seconds is the compromise.
  use GenServer, shutdown: 10_000

  require Logger

  alias Mydia.Events
  alias Mydia.Events.Event
  alias Mydia.Repo

  @max_batch 100
  @flush_interval_ms 200
  @max_buffer 5_000
  @max_mailbox 10_000

  # `enqueue/2` runs in the caller's process and must never block on the
  # writer, so it cannot ask the writer's own state for the configured
  # mailbox limit (a GenServer.call would queue up behind the very backlog
  # it is trying to detect). Instead the writer stashes the limit and a
  # shared drop counter in its own process dictionary at init, where
  # `Process.info/2` can read them from any process without sending the
  # writer a message, even while it is busy.
  @mailbox_guard_key :mydia_events_writer_mailbox_guard

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

  The event is dropped instead of cast when the writer's mailbox is already
  at its configured limit. This bounds total pending events (mailbox plus
  buffer) even though the writer can be blocked in `Repo.insert_all/2` for
  seconds at a time under write contention while casts keep arriving.
  """
  @spec enqueue(map(), GenServer.server()) :: :ok
  def enqueue(attrs, server \\ __MODULE__) do
    case build(attrs) do
      {:ok, event} ->
        cast_or_drop(server, event)

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

  # Resolves `server` to a pid and checks its mailbox before casting. An atom
  # that is not currently registered resolves to no pid, in which case this
  # casts unconditionally: GenServer.cast/2 to an unregistered name is
  # already a silent no-op, and short-circuiting here would change that
  # existing behavior. A pid whose mailbox guard is missing (for example a
  # process that is not a Mydia.Events.Writer at all) also just casts.
  defp cast_or_drop(server, event) do
    case resolve_pid(server) do
      nil ->
        GenServer.cast(server, {:event, event})

      pid ->
        case Process.info(pid, [:message_queue_len, :dictionary]) do
          [{:message_queue_len, len}, {:dictionary, dict}] ->
            case Keyword.get(dict, @mailbox_guard_key) do
              {max_mailbox, drop_counter} when len >= max_mailbox ->
                :counters.add(drop_counter, 1, 1)
                :ok

              _ ->
                GenServer.cast(server, {:event, event})
            end

          # Process.info/2 returns nil for a pid that is no longer alive.
          nil ->
            GenServer.cast(server, {:event, event})
        end
    end
  end

  defp resolve_pid(pid) when is_pid(pid), do: pid
  defp resolve_pid(name) when is_atom(name), do: Process.whereis(name)
  defp resolve_pid(_other), do: nil

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

    max_mailbox = Keyword.get(opts, :max_mailbox, @max_mailbox)
    Process.put(@mailbox_guard_key, {max_mailbox, :counters.new(1, [])})

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

  defp do_flush(%{size: 0} = state) do
    log_mailbox_dropped()
    cancel_timer(state)
  end

  defp do_flush(state) do
    events = :queue.to_list(state.buffer)
    log_dropped(state.dropped)
    log_mailbox_dropped()

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

  # Runs on the writer's own flush cadence rather than per drop, so a mailbox
  # stall logs at most once per flush interval instead of flooding at exactly
  # the moment logging would be least welcome. Reads and zeroes the counter
  # that cast_or_drop/2 increments from arbitrary caller processes.
  defp log_mailbox_dropped do
    case Process.get(@mailbox_guard_key) do
      {_max_mailbox, drop_counter} ->
        count = :counters.get(drop_counter, 1)

        if count > 0 do
          :counters.sub(drop_counter, 1, count)
          Logger.warning("Events.Writer mailbox full, dropped #{count} event(s)")
        end

      nil ->
        :ok
    end
  end

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(%{timer: ref} = state) do
    Process.cancel_timer(ref)
    %{state | timer: nil}
  end
end
