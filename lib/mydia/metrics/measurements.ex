defmodule Mydia.Metrics.Measurements do
  @moduledoc """
  Poller callbacks for `Mydia.Metrics.Supervisor`. Each emits
  `[:mydia, :metrics, ...]` events that `Mydia.Metrics.Definitions` turns into
  gauges.

  Every callback runs inside `safely/2`. `telemetry_poller` drops a
  measurement that raises for the rest of the boot, so one failing query would
  otherwise blank that family until restart. Labelled gauges are zero-filled
  over their known label values so a count that drops to nothing reads 0, not
  its last non-zero value.
  """

  require Logger

  alias Mydia.{Downloads, Jobs, Library, Media, Settings, Streaming}
  alias Mydia.Downloads.ClientHealth

  @memory_kinds [:total, :processes, :binary, :ets, :atom]
  @episode_states ~w(downloaded missing upcoming tba)
  @download_states [:active, :failed, :awaiting_import]

  def vm do
    safely(:vm, fn ->
      memory = :erlang.memory()

      for kind <- @memory_kinds do
        emit(:vm_memory, Keyword.fetch!(memory, kind), %{kind: Atom.to_string(kind)})
      end

      emit(:vm_run_queue, :erlang.statistics(:total_run_queue_lengths), %{})
      emit(:vm_processes, :erlang.system_info(:process_count), %{})
      {uptime_ms, _} = :erlang.statistics(:wall_clock)
      emit(:uptime, div(uptime_ms, 1000), %{})
    end)
  end

  def streaming do
    safely(:streaming, fn ->
      counts = Streaming.session_counts()
      emit(:hls_sessions, counts.hls_copy, %{mode: "copy"})
      emit(:hls_sessions, counts.hls_transcode, %{mode: "transcode"})
      emit(:direct_play_sessions, counts.direct, %{kind: "direct"})
      emit(:direct_play_sessions, counts.remux, %{kind: "remux"})
    end)
  end

  def build_info do
    safely(:build_info, fn ->
      emit(:build_info, 1, %{version: Mydia.System.app_version()})
    end)
  end

  def library do
    safely(:library, fn ->
      emit(:library_items, Media.count_movies(), %{type: "movie"})
      emit(:library_items, Media.count_tv_shows(), %{type: "tv_show"})

      counts = Media.episode_state_counts()

      for state <- @episode_states, monitored <- [true, false] do
        emit(:library_episodes, Map.get(counts, {state, monitored}, 0), %{
          state: state,
          monitored: to_string(monitored)
        })
      end

      emit(:library_media_files, Library.media_file_count(), %{})
      emit(:library_size, Library.total_storage_bytes(), %{})
    end)
  end

  def downloads do
    safely(:downloads, fn ->
      counts = Downloads.count_by_state()

      for state <- @download_states do
        emit(:downloads, Map.fetch!(counts, state), %{state: Atom.to_string(state)})
      end
    end)
  end

  def download_clients do
    safely(:download_clients, fn ->
      configs = Settings.list_download_client_configs()
      status_map = ClientHealth.status_map(configs)

      for {value, name} <- client_up_values(configs, status_map) do
        emit(:download_client_up, value, %{client: name})
      end
    end)
  end

  # Pairs each config's health with its configured `name`, never its id, so
  # the Prometheus label survives a delete/recreate instead of growing
  # without bound (`config.id` is a `:binary_id` primary key). `:unknown` and
  # `:disabled` clients have no up/down answer to give, so they're left out
  # rather than reported as either.
  @doc false
  @spec client_up_values(
          [%{required(:id) => term(), required(:name) => String.t(), optional(atom()) => term()}],
          %{String.t() => %{status: atom()}}
        ) :: [{0 | 1, String.t()}]
  def client_up_values(configs, status_map) do
    for config <- configs,
        {:ok, %{status: status}} <- [Map.fetch(status_map, config.id)],
        status in [:healthy, :unhealthy] do
      {if(status == :healthy, do: 1, else: 0), config.name}
    end
  end

  def oban do
    safely(:oban, fn ->
      counts = Jobs.count_by_queue_and_state()

      queues =
        configured_queues()
        |> Enum.concat(Enum.map(Map.keys(counts), &elem(&1, 0)))
        |> Enum.uniq()

      for queue <- queues, state <- Jobs.pending_states() do
        emit(:oban_jobs, Map.get(counts, {queue, state}, 0), %{queue: queue, state: state})
      end
    end)
  end

  @doc false
  @spec safely(atom(), (-> any())) :: :ok
  def safely(family, fun) do
    fun.()
    :ok
  rescue
    exception ->
      Logger.warning("metrics measurement #{family} failed: #{Exception.message(exception)}")
      :ok
  catch
    :exit, reason ->
      Logger.warning("metrics measurement #{family} failed: #{inspect(reason)}")
      :ok
  end

  defp configured_queues do
    case Application.get_env(:mydia, Oban, [])[:queues] do
      queues when is_list(queues) -> Enum.map(queues, fn {name, _} -> to_string(name) end)
      _ -> []
    end
  end

  defp emit(event, value, metadata) do
    :telemetry.execute([:mydia, :metrics, event], %{value: value}, metadata)
  end
end
