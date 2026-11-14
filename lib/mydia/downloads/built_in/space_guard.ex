defmodule Mydia.Downloads.BuiltIn.SpaceGuard do
  @moduledoc """
  Pauses the built-in client's downloading torrents when the download volume
  drops below `Config.min_free_space_bytes`, and resumes exactly those once
  there is room again.

  Every `interval_ms` (60 seconds by default) it measures free space on
  `config.download_path`:

    * below the reserve: every torrent the engine is downloading is paused and
      its info hash recorded in `<state_dir>/space-paused`; torrents that start
      downloading later in the same low period are paused too. The `Status`
      part `:disk` becomes `{:low, %{free: _, reserve: _}}`.
    * above the reserve plus 1 GiB: the recorded torrents are resumed, the file
      deleted and `:disk` set back to `:ok`. The gap keeps it from flapping.
    * in between: nothing changes either way.

  A recorded torrent found downloading while low was resumed by hand. It is
  dropped from the record and left alone until the next low crossing.

  The record file survives a restart, so torrents paused for space resume once
  there is room after a reboot. A failed write of it is retried at the start
  of every check until one lands, whatever that check then finds; otherwise a
  torrent paused just before a restart would stay paused for good. A reserve
  of 0 disables the guard; anything
  still recorded is resumed. Low disk space is not a blocking reason: imports,
  removals and seeding carry on.

  A failed measurement changes nothing and is logged at most once an hour.
  Client errors are logged and retried on the next check. Nothing is sent to
  the client while `Status` reports a blocking reason (engine starting, VPN
  down), since every call would fail.
  """

  use GenServer

  require Logger

  alias Mydia.Downloads.BuiltIn
  alias Mydia.Downloads.BuiltIn.{Config, DiskSpace, Status}
  alias Mydia.Downloads.Client
  alias Mydia.Downloads.Queue.ClientSelection

  # The recovery gap is binary, the reserve itself decimal gigabytes.
  @gib 1024 ** 3
  @gb 1_000_000_000
  @record_file "space-paused"
  @warn_every_ms :timer.hours(1)

  @doc """
  Options: `:config` (required), `:status` (the `Status` server, default
  `Status`), `:free_bytes` (default `&DiskSpace.free_bytes/1`), `:client`
  (`{adapter, config_map}`; nil resolves the built-in client on each check),
  `:interval_ms` (default 60_000), `:runtime` (default `&BuiltIn.runtime/0`;
  its config's reserve wins over `:config`'s, so a changed reserve applies
  without a restart), `:write_record` (`(path, ids) -> :ok | {:error, _}`,
  default `write_record_file/2`) and `:name`.
  """
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc "Runs one check now and returns once it is done."
  @spec check_now(GenServer.server()) :: :ok
  def check_now(server), do: GenServer.call(server, :check_now, :timer.seconds(30))

  @impl true
  def init(opts) do
    config = Keyword.fetch!(opts, :config)
    status = Keyword.get(opts, :status, Status)

    state = %{
      config: config,
      status: status,
      free_bytes: Keyword.get(opts, :free_bytes, &DiskSpace.free_bytes/1),
      client: Keyword.get(opts, :client),
      interval_ms: Keyword.get(opts, :interval_ms, 60_000),
      runtime: Keyword.get(opts, :runtime, &BuiltIn.runtime/0),
      write_record: Keyword.get(opts, :write_record, &write_record_file/2),
      recorded: read_record(config),
      # The record on disk lags `recorded` after a failed write.
      dirty: false,
      exempt: MapSet.new(),
      disk: initial_disk(status),
      last_warned: nil
    }

    schedule(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:check_now, _from, state), do: {:reply, :ok, check(state)}

  @impl true
  def handle_info(:check, state) do
    state = check(state)
    schedule(state)
    {:noreply, state}
  end

  defp schedule(state), do: Process.send_after(self(), :check, state.interval_ms)

  defp check(state) do
    state = if state.dirty, do: write_record(state), else: state
    check(state, reserve(state))
  end

  defp check(state, 0), do: recover(state)

  defp check(state, reserve) do
    case state.free_bytes.(state.config.download_path) do
      {:ok, free} when free < reserve -> low(state, free, reserve)
      {:ok, free} when free > reserve + @gib -> recover(state)
      {:ok, _between} -> state
      {:error, reason} -> warn_unmeasurable(state, reason)
    end
  end

  # The Manager refreshes the runtime entry when only the reserve changes,
  # without restarting this process.
  defp reserve(state) do
    case state.runtime.() do
      %{config: %Config{min_free_space_bytes: reserve}} -> reserve
      _ -> state.config.min_free_space_bytes
    end
  end

  # A guard restarted on its own (a crash under the tree) finds the banner
  # its previous run set, and must be able to clear it.
  defp initial_disk(status) do
    Status.get(status).disk
  catch
    :exit, _ -> :ok
  end

  defp low(state, free, reserve) do
    state =
      put_disk(
        state,
        {:low, %{free: DiskSpace.format_gb(free), reserve: "#{div(reserve, @gb)} GB"}}
      )

    with_torrents(state, fn adapter, client_config, torrents ->
      torrents
      |> Enum.filter(&(&1.state == :downloading))
      |> Enum.reduce(state, &pause_for_space(&2, &1.id, adapter, client_config))
    end)
  end

  defp pause_for_space(state, id, adapter, client_config) do
    cond do
      # Paused by us and downloading again: the user resumed it by hand.
      MapSet.member?(state.recorded, id) ->
        %{
          state
          | recorded: MapSet.delete(state.recorded, id),
            exempt: MapSet.put(state.exempt, id)
        }
        |> write_record()

      MapSet.member?(state.exempt, id) ->
        state

      true ->
        case Client.pause_torrent(adapter, client_config, id) do
          :ok ->
            write_record(%{state | recorded: MapSet.put(state.recorded, id)})

          {:error, reason} ->
            Logger.warning("Space guard could not pause torrent #{id}: #{inspect(reason)}")
            state
        end
    end
  end

  defp recover(state) do
    state = put_disk(%{state | exempt: MapSet.new()}, :ok)

    if MapSet.size(state.recorded) == 0 do
      state
    else
      with_torrents(state, fn adapter, client_config, torrents ->
        present = MapSet.new(torrents, & &1.id)

        state.recorded
        |> Enum.reduce(state, &resume_recorded(&2, &1, present, adapter, client_config))
        |> write_record()
      end)
    end
  end

  # A recorded torrent the client no longer has was removed meanwhile.
  defp resume_recorded(state, id, present, adapter, client_config) do
    resumed? =
      not MapSet.member?(present, id) or
        case Client.resume_torrent(adapter, client_config, id) do
          :ok ->
            true

          {:error, reason} ->
            Logger.warning("Space guard could not resume torrent #{id}: #{inspect(reason)}")
            false
        end

    if resumed?, do: %{state | recorded: MapSet.delete(state.recorded, id)}, else: state
  end

  # Runs `fun` with the client and its torrents, or leaves the state as it is
  # (retrying on the next check) when the client is blocked or errors.
  defp with_torrents(state, fun) do
    with nil <- blocking_reason(state),
         {:ok, adapter, client_config} <- client(state),
         {:ok, torrents} <- Client.list_torrents(adapter, client_config, []) do
      fun.(adapter, client_config, torrents)
    else
      {:error, reason} ->
        Logger.warning("Space guard could not list torrents: #{inspect(reason)}")
        state

      _blocked ->
        state
    end
  end

  defp blocking_reason(state) do
    Status.blocking_reason(Status.get(state.status))
  catch
    :exit, _ -> :status_unavailable
  end

  defp client(%{client: {adapter, client_config}}), do: {:ok, adapter, client_config}
  defp client(%{client: nil}), do: ClientSelection.resolve_adapter(BuiltIn.name())

  defp put_disk(%{disk: disk} = state, disk), do: state

  defp put_disk(state, disk) do
    Status.put(state.status, :disk, disk)
    %{state | disk: disk}
  end

  defp warn_unmeasurable(state, reason) do
    now = System.monotonic_time(:millisecond)

    if state.last_warned == nil or now - state.last_warned >= @warn_every_ms do
      Logger.warning(
        "Space guard could not measure free space on #{state.config.download_path}: #{inspect(reason)}"
      )

      %{state | last_warned: now}
    else
      state
    end
  end

  defp record_path(%Config{state_dir: dir}), do: Path.join(dir, @record_file)

  defp read_record(config) do
    case File.read(record_path(config)) do
      {:ok, contents} -> contents |> String.split("\n", trim: true) |> MapSet.new()
      {:error, _} -> MapSet.new()
    end
  end

  defp write_record(state) do
    path = record_path(state.config)

    case state.write_record.(path, state.recorded) do
      :ok ->
        %{state | dirty: false}

      {:error, reason} ->
        Logger.warning("Space guard could not update #{path}: #{inspect(reason)}")
        %{state | dirty: true}
    end
  end

  @doc """
  Writes the recorded info hashes to `path`: to a temporary file, then
  renamed, so a crash never leaves half a record. An empty set removes the
  file.
  """
  @spec write_record_file(Path.t(), MapSet.t(String.t())) :: :ok | {:error, term()}
  def write_record_file(path, ids) do
    if MapSet.size(ids) == 0 do
      case File.rm(path) do
        {:error, :enoent} -> :ok
        other -> other
      end
    else
      tmp = path <> ".tmp"
      contents = ids |> Enum.sort() |> Enum.join("\n")

      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(tmp, contents <> "\n") do
        File.rename(tmp, path)
      end
    end
  end
end
