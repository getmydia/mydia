defmodule Mydia.CrashReporter.Queue do
  @moduledoc """
  Local queue for crash reports.

  Manages a persistent queue of crash reports that need to be sent to the metadata relay.
  Handles retry logic for failed sends and ensures reports are not lost if the metadata
  relay is temporarily unavailable.

  ## Features
  - In-memory queue with ETS persistence
  - Automatic retry with configurable exponential backoff
  - Configurable max retries and retry duration
  - Background worker for processing queue every 30 seconds
  - Graceful handling of both network and server errors

  ## Configuration

  Retry behavior can be configured in config.exs:

      config :mydia, Mydia.CrashReporter.Queue,
        initial_retry_delay: 60_000,        # 1 minute (in milliseconds)
        max_retry_delay: 480_000,           # 8 minutes (in milliseconds)
        max_retries: 10,                    # Maximum retry attempts
        max_retry_duration: 24 * 60 * 60   # 24 hours (in seconds)

  ## Retry Strategy

  The queue uses exponential backoff with the following behavior:
  - Initial delay: 1 minute (configurable)
  - Delay doubles after each retry: 1min, 2min, 4min, 8min, 8min, ...
  - Max delay cap: 8 minutes (configurable)
  - Reports are deleted only after:
    - Exceeding max retries (default: 10 attempts), OR
    - Exceeding max retry duration (default: 24 hours), OR
    - The relay rejecting the body with a 400 or 413, which no retry can fix
  - Successful delivery immediately stops further retries

  This strategy ensures crash reports survive temporary network issues and server
  outages while preventing indefinite retention of undeliverable reports.
  """

  use GenServer
  require Logger

  alias Mydia.CrashReporter.Sender

  @table_name :crash_report_queue

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Enqueues a crash report for async sending.
  """
  @spec enqueue(map()) :: :ok
  def enqueue(report) do
    GenServer.cast(__MODULE__, {:enqueue, report})
  end

  @doc """
  Returns the number of reports in the queue.
  """
  @spec count() :: non_neg_integer()
  def count do
    try do
      :ets.info(@table_name, :size) || 0
    rescue
      _ -> 0
    end
  end

  @doc """
  Returns all reports in the queue with their metadata.
  """
  @spec list_all() :: [map()]
  def list_all do
    try do
      :ets.tab2list(@table_name)
      |> Enum.map(fn {_id, entry} -> entry end)
      |> Enum.sort_by(& &1.enqueued_at)
    rescue
      _ -> []
    end
  end

  @doc """
  Clears all reports from the queue.
  """
  @spec clear_all() :: :ok
  def clear_all do
    GenServer.call(__MODULE__, :clear_all)
  end

  @doc """
  Processes all queued reports immediately (for testing).
  """
  @spec process_all() :: :ok
  def process_all do
    GenServer.call(__MODULE__, :process_all)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    # Create ETS table for persistent queue
    :ets.new(@table_name, [:named_table, :public, :ordered_set])

    # Schedule initial queue processing
    schedule_process_queue()

    {:ok, %{processing: false}}
  end

  @impl true
  def handle_cast({:enqueue, report}, state) do
    # Generate unique ID for the report
    report_id = generate_id()

    # Store in ETS with metadata
    now = System.monotonic_time(:second)

    entry = %{
      id: report_id,
      report: report,
      retries: 0,
      enqueued_at: now,
      last_attempt_at: nil,
      next_retry_at: now
    }

    :ets.insert(@table_name, {report_id, entry})

    # Trigger immediate processing if not already processing
    unless state.processing do
      send(self(), :process_queue)
    end

    {:noreply, state}
  end

  @impl true
  def handle_call(:clear_all, _from, state) do
    :ets.delete_all_objects(@table_name)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:process_all, _from, state) do
    process_queue(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:process_queue, state) do
    new_state = process_queue(state)

    # Schedule next processing
    schedule_process_queue()

    {:noreply, new_state}
  end

  # Private functions

  defp process_queue(state) do
    # Get all entries from queue
    entries =
      :ets.tab2list(@table_name)
      |> Enum.map(fn {_id, entry} -> entry end)
      |> Enum.sort_by(& &1.enqueued_at)

    if entries == [] do
      %{state | processing: false}
    else
      %{state | processing: true}
      |> process_entries(entries)
      |> Map.put(:processing, false)
    end
  end

  defp process_entries(state, []), do: state

  defp process_entries(state, [entry | rest]) do
    # Check if we should retry this entry
    if should_retry?(entry) do
      case Sender.send_report(entry.report) do
        {:ok, _} ->
          # Success - remove from queue
          :ets.delete(@table_name, entry.id)
          Logger.debug("Crash report #{entry.id} sent successfully")

        {:error, {:validation_error, response}} ->
          # The relay rejected the body. The same body can never succeed, so
          # retrying only repeats the rejection up to max_retries times.
          :ets.delete(@table_name, entry.id)

          Logger.warning(
            "Crash report #{entry.id} (#{inspect(Map.get(entry.report, :error_type))}) " <>
              "rejected by the relay, discarding. Response: " <>
              inspect(response, limit: 10, printable_limit: 500)
          )

        {:error, reason} ->
          # Failed - increment retry count and schedule next retry
          now = System.monotonic_time(:second)
          next_retry = entry.retries + 1
          delay_seconds = div(retry_delay(next_retry), 1000)

          # Use Map.put to support old entries without next_retry_at
          updated_entry =
            entry
            |> Map.put(:retries, next_retry)
            |> Map.put(:last_attempt_at, now)
            |> Map.put(:next_retry_at, now + delay_seconds)

          max_retries = get_config(:max_retries)
          max_duration = get_config(:max_retry_duration)

          cond do
            updated_entry.retries >= max_retries ->
              # Max retries exceeded - remove from queue
              :ets.delete(@table_name, entry.id)

              Logger.warning(
                "Crash report #{entry.id} failed after #{max_retries} attempts, discarding. Reason: #{inspect(reason)}"
              )

            now - entry.enqueued_at >= max_duration ->
              # Max retry duration exceeded - remove from queue
              :ets.delete(@table_name, entry.id)

              Logger.warning(
                "Crash report #{entry.id} exceeded max retry duration (#{max_duration}s), discarding. Reason: #{inspect(reason)}"
              )

            true ->
              # Update entry with new retry count and schedule
              :ets.insert(@table_name, {entry.id, updated_entry})

              Logger.debug(
                "Crash report #{entry.id} failed, will retry in #{delay_seconds}s (#{updated_entry.retries}/#{max_retries}). Reason: #{inspect(reason)}"
              )
          end
      end
    end

    process_entries(state, rest)
  end

  defp should_retry?(entry) do
    max_retries = get_config(:max_retries)
    max_duration = get_config(:max_retry_duration)
    now = System.monotonic_time(:second)

    cond do
      # Don't retry if max retries exceeded
      entry.retries >= max_retries ->
        false

      # Don't retry if max duration exceeded
      now - entry.enqueued_at >= max_duration ->
        false

      # Check if it's time for the next retry
      true ->
        # Handle both old entries (without next_retry_at) and new entries (with next_retry_at)
        next_retry_at = Map.get(entry, :next_retry_at, entry.enqueued_at)
        now >= next_retry_at
    end
  end

  defp retry_delay(retries) do
    # Exponential backoff with max delay
    initial_delay = get_config(:initial_retry_delay)
    max_delay = get_config(:max_retry_delay)

    delay = initial_delay * :math.pow(2, retries)
    min(trunc(delay), max_delay)
  end

  defp get_config(key) do
    Application.get_env(:mydia, __MODULE__, [])
    |> Keyword.get(key, default_config(key))
  end

  defp default_config(:initial_retry_delay), do: 60_000
  defp default_config(:max_retry_delay), do: 480_000
  defp default_config(:max_retries), do: 10
  defp default_config(:max_retry_duration), do: 24 * 60 * 60

  defp schedule_process_queue do
    # Process queue every 30 seconds
    Process.send_after(self(), :process_queue, 30_000)
  end

  defp generate_id do
    # Generate a unique ID using timestamp and random bytes
    timestamp = System.system_time(:millisecond)
    random = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    "#{timestamp}-#{random}"
  end
end
