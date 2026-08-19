defmodule Mydia.Downloads.Seedbox.Fetcher do
  @moduledoc """
  Per-download GenServer that pulls a completed torrent's files from a
  remote seedbox into the configured local download directory over SFTP.

  Registered under
  `{:via, Registry, {FetcherRegistry, {:seedbox_fetcher, download_id}, client_name}}`
  — the third `:via` element stores `client_name` alongside the pid so
  `count_running/1` can enforce `max_concurrent_transfers` per client
  without a separate index. Mirrors `Debrid.Fetcher`'s shape: `DynamicSupervisor`
  strategy `:one_for_one`, `restart: :temporary`, atomic claim via
  `{:error, {:already_started, _}}` treated as success.

  On completion, sets `Download.metadata["save_path"]` to the local path —
  the same signal `Debrid.Fetcher` uses — and deliberately does NOT set
  `Download.completed_at`; see the plan's Global Constraints for why.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Mydia.Downloads.Seedbox.Connection
  alias Mydia.Downloads.{Download, History}
  alias Mydia.Repo

  @registry Mydia.Downloads.Seedbox.FetcherRegistry
  @supervisor Mydia.Downloads.Seedbox.FetcherSupervisor
  @max_retries 3
  @retry_delay_base_ms 5_000
  @chunk_size 1_048_576

  @doc false
  def child_spec(opts) do
    download_id = Keyword.fetch!(opts, :download_id)

    %{
      id: {__MODULE__, download_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  @doc false
  def start_link(opts) do
    download_id = Keyword.fetch!(opts, :download_id)
    client_name = Keyword.fetch!(opts, :client_name)
    name = {:via, Registry, {@registry, {:seedbox_fetcher, download_id}, client_name}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Atomically starts (or no-ops on) a Fetcher for the given download.
  """
  @spec claim(keyword()) :: :ok | {:error, term()}
  def claim(opts) do
    case DynamicSupervisor.start_child(@supervisor, {__MODULE__, opts}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec whereis(binary()) :: {:ok, pid()} | :error
  def whereis(download_id) do
    case Registry.lookup(@registry, {:seedbox_fetcher, download_id}) do
      [{pid, _client_name}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc "Counts currently-registered fetchers for `client_name` — used to enforce max_concurrent_transfers."
  @spec count_running(String.t()) :: non_neg_integer()
  def count_running(client_name) do
    @registry
    |> Registry.select([{{:_, :_, :"$1"}, [{:==, :"$1", client_name}], [true]}])
    |> length()
  end

  ## ── GenServer ────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    state = %{
      download_id: Keyword.fetch!(opts, :download_id),
      client_name: Keyword.fetch!(opts, :client_name),
      remote_fetch: Keyword.fetch!(opts, :remote_fetch),
      remote_path: Keyword.fetch!(opts, :remote_path),
      download_directory: Keyword.fetch!(opts, :download_directory),
      max_retries: Keyword.get(opts, :max_retries, @max_retries),
      retries_left: Keyword.get(opts, :max_retries, @max_retries),
      retry_delay_base_ms: Keyword.get(opts, :retry_delay_base_ms, @retry_delay_base_ms)
    }

    send(self(), :begin)
    {:ok, state}
  end

  @impl true
  def handle_info(:begin, state) do
    case run(state) do
      {:ok, _} ->
        {:stop, :normal, state}

      # The row was deleted while we were pulling (cancelled from the UI, an
      # import that cleaned up). Terminal, and deliberately ahead of the retry
      # clause: there is nothing left to fetch for and nothing to mark failed,
      # and `run/1` has already deleted the remote source by this point, so a
      # retry would re-open SFTP for a path that is gone (issue #281).
      :download_deleted ->
        Logger.info(
          "Seedbox fetcher stopping: download row no longer exists " <>
            "(download_id=#{state.download_id})"
        )

        {:stop, :normal, state}

      {:error, reason} when state.retries_left > 0 ->
        Logger.warning(
          "Seedbox fetch attempt failed for download_id=#{state.download_id} " <>
            "(#{state.retries_left} retries left): #{inspect(reason)}"
        )

        retry_ms = (state.max_retries - state.retries_left + 1) * state.retry_delay_base_ms
        Process.send_after(self(), :begin, retry_ms)
        {:noreply, %{state | retries_left: state.retries_left - 1}}

      {:error, reason} ->
        fail_download(state, reason)
        {:stop, :normal, state}
    end
  end

  defp run(state) do
    case Connection.open(state.remote_fetch) do
      {:ok, channel, cleanup} ->
        try do
          case transfer_all(channel, state) do
            :ok ->
              # Best-effort: deletion never blocks or fails an otherwise
              # successful download. The files are already safely verified
              # on local disk at this point, so a cleanup hiccup on the
              # remote side (permissions, transient SFTP error, path
              # already gone) shouldn't force a from-scratch re-download.
              maybe_delete_remote(channel, state)
              finalize(state)

            {:error, _reason} = err ->
              err
          end
        after
          cleanup.()
        end

      {:error, _reason} = err ->
        err
    end
  end

  defp transfer_all(channel, state) do
    case to_stat(:ssh_sftp.read_file_info(channel, to_charlist(state.remote_path))) do
      {:ok, %File.Stat{type: :regular, size: size}} ->
        local_path = local_final_path(state, Path.basename(state.remote_path))
        transfer_file(channel, state.remote_path, local_path, size, state)

      {:ok, %File.Stat{type: :directory}} ->
        transfer_directory(channel, state.remote_path, state)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp transfer_directory(channel, remote_dir, state) do
    case list_files_recursive(channel, remote_dir, remote_dir) do
      {:ok, entries} ->
        Enum.reduce_while(entries, :ok, fn {remote_file, relative_path, size}, :ok ->
          local_path = local_final_path(state, relative_path)

          case transfer_file(channel, remote_file, local_path, size, state) do
            :ok -> {:cont, :ok}
            {:error, _} = err -> {:halt, err}
          end
        end)

      {:error, _} = err ->
        err
    end
  end

  # Walks `dir`, recursing into subdirectories, returning
  # `{remote_path, path_relative_to_root, size}` for every regular file.
  # `root` stays fixed across the recursion so `relative_path` mirrors the
  # torrent's own directory structure under the local download directory.
  defp list_files_recursive(channel, dir, root) do
    case :ssh_sftp.list_dir(channel, to_charlist(dir)) do
      {:ok, names} ->
        names
        |> Enum.map(&to_string/1)
        |> Enum.reject(&(&1 in [".", ".."]))
        |> Enum.reduce_while({:ok, []}, fn name, {:ok, acc} ->
          entry_path = Path.join(dir, name)

          case to_stat(:ssh_sftp.read_file_info(channel, to_charlist(entry_path))) do
            {:ok, %File.Stat{type: :directory}} ->
              case list_files_recursive(channel, entry_path, root) do
                {:ok, nested} -> {:cont, {:ok, nested ++ acc}}
                {:error, _} = err -> {:halt, err}
              end

            {:ok, %File.Stat{type: :regular, size: size}} ->
              relative = Path.relative_to(entry_path, root)
              {:cont, {:ok, [{entry_path, relative, size} | acc]}}

            {:ok, _other_type} ->
              {:cont, {:ok, acc}}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end
        end)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # `delete_after_transfer` round-trips through the admin UI's form params
  # and the `connection_settings` JSON column (`Mydia.Settings.JsonMapType`,
  # no per-key type casting) the same way `enabled`/`port`/
  # `max_concurrent_transfers` do elsewhere in this feature — a checkbox
  # saved through `<.input type="checkbox">` submits the string "true", not
  # a real boolean. A plain `if Map.get(...) do` truthy check would treat
  # the STRING "false" as truthy (only `nil`/`false` are falsy in Elixir),
  # which would delete the remote copy after every verified transfer once
  # this field is ever saved as a string. Matched against both forms, same
  # as `DownloadClientConfig.validate_remote_fetch_config/1`'s `enabled`.
  defp maybe_delete_remote(channel, state) do
    if Map.get(state.remote_fetch, "delete_after_transfer", false) in [true, "true"] do
      case delete_remote_recursive(channel, state.remote_path) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "Seedbox remote cleanup failed for download_id=#{state.download_id} " <>
              "(local transfer already verified, download proceeds): #{inspect(reason)}"
          )

          :ok
      end
    else
      :ok
    end
  end

  defp delete_remote_recursive(channel, remote_path) do
    case to_stat(:ssh_sftp.read_file_info(channel, to_charlist(remote_path))) do
      {:ok, %File.Stat{type: :directory}} ->
        delete_remote_directory(channel, remote_path)

      {:ok, %File.Stat{type: :regular}} ->
        :ssh_sftp.delete(channel, to_charlist(remote_path))

      {:ok, _other_type} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp delete_remote_directory(channel, remote_path) do
    with {:ok, names} <- :ssh_sftp.list_dir(channel, to_charlist(remote_path)) do
      names
      |> Enum.map(&to_string/1)
      |> Enum.reject(&(&1 in [".", ".."]))
      |> Enum.reduce_while(:ok, fn name, :ok ->
        case delete_remote_recursive(channel, Path.join(remote_path, name)) do
          :ok -> {:cont, :ok}
          {:error, _} = err -> {:halt, err}
        end
      end)
      |> case do
        :ok -> :ssh_sftp.del_dir(channel, to_charlist(remote_path))
        err -> err
      end
    end
  end

  defp to_stat({:ok, raw}), do: {:ok, File.Stat.from_record(raw)}
  defp to_stat({:error, _} = err), do: err

  defp transfer_file(channel, remote_path, local_path, expected_size, state) do
    if already_complete?(local_path, expected_size) do
      # A previous attempt already transferred and verified this exact file
      # (same final size) — most relevant for a season pack retry after a
      # later file in the directory failed. Skip straight to success rather
      # than redownloading it from offset 0: `bytes_pulled` is set to what
      # it would be had this file's transfer just finished, matching the
      # normal completion path below.
      update_bytes_pulled(state.download_id, expected_size)
      :ok
    else
      File.mkdir_p!(Path.dirname(local_path))
      part_path = local_path <> ".part"
      offset = prepare_part(part_path, state.download_id)

      case stream_file(channel, remote_path, part_path, offset, state.download_id) do
        :ok -> verify_and_finalize_file(part_path, local_path, expected_size)
        {:error, _} = err -> err
      end
    end
  end

  # Whole-file resume, one level up from `.part`-file offset resume: if the
  # FINAL (non-`.part`) local path already exists with the exact size the
  # remote reported, this file is done and untouched — don't re-stream it.
  defp already_complete?(local_path, expected_size) do
    case File.stat(local_path) do
      {:ok, %File.Stat{type: :regular, size: ^expected_size}} -> true
      _ -> false
    end
  end

  defp prepare_part(part_path, download_id) do
    if File.exists?(part_path) do
      size = File.stat!(part_path).size
      update_bytes_pulled(download_id, size)
      size
    else
      File.touch!(part_path)
      update_bytes_pulled(download_id, 0)
      0
    end
  end

  defp stream_file(channel, remote_path, part_path, offset, download_id) do
    with {:ok, handle} <- :ssh_sftp.open(channel, to_charlist(remote_path), [:read, :binary]),
         {:ok, _pos} <- maybe_seek(channel, handle, offset) do
      result = read_loop(channel, handle, part_path, offset, download_id)
      :ssh_sftp.close(channel, handle)
      result
    end
  end

  defp maybe_seek(_channel, _handle, 0), do: {:ok, 0}

  defp maybe_seek(channel, handle, offset),
    do: :ssh_sftp.position(channel, handle, {:bof, offset})

  defp read_loop(channel, handle, part_path, total_written, download_id) do
    case :ssh_sftp.read(channel, handle, @chunk_size) do
      {:ok, data} ->
        File.write!(part_path, data, [:append, :binary])
        new_total = total_written + byte_size(data)
        update_bytes_pulled(download_id, new_total)
        read_loop(channel, handle, part_path, new_total, download_id)

      :eof ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp verify_and_finalize_file(part_path, local_path, expected_size) do
    actual_size = File.stat!(part_path).size

    if actual_size == expected_size do
      File.rename(part_path, local_path)
    else
      {:error, {:size_mismatch, expected: expected_size, actual: actual_size}}
    end
  end

  defp update_bytes_pulled(download_id, n) do
    import Ecto.Query

    Repo.update_all(
      from(d in Download, where: d.id == ^download_id),
      set: [bytes_pulled: n, last_progress_at: DateTime.utc_now(), last_known_bytes: n]
    )

    :ok
  end

  defp finalize(state) do
    case History.get_download(state.download_id) do
      # Cancelled or deleted while the payload was being pulled (issue #281).
      # Terminal rather than an error: this runs after `transfer_all/2` has
      # copied everything and `maybe_delete_remote/2` has removed the source, so
      # a retry would re-open SFTP for a remote path that no longer exists.
      nil ->
        :download_deleted

      download ->
        save_path = local_download_dir(state)
        new_metadata = Map.merge(download.metadata || %{}, %{"save_path" => save_path})

        case History.update_download(download, %{metadata: new_metadata}) do
          {:ok, _} ->
            {:ok, :done}

          # Deleted between the lookup above and this write — same race, narrower
          # window, and just as terminal (issue #281). An ordinary changeset
          # error still surfaces as retryable.
          {:error, changeset} ->
            if History.stale_changeset?(changeset),
              do: :download_deleted,
              else: {:error, {:finalize_failed, changeset}}
        end
    end
  end

  defp local_download_dir(state), do: Path.join(state.download_directory, state.download_id)
  defp local_final_path(state, filename), do: Path.join(local_download_dir(state), filename)

  defp fail_download(state, reason) do
    Logger.warning(
      "Seedbox fetch failed for download_id=#{state.download_id}: #{inspect(reason)}"
    )

    case History.get_download(state.download_id) do
      %Download{} = d ->
        History.update_download(d, %{
          import_failed_at: DateTime.utc_now(),
          import_last_error: "seedbox_fetch_failed: #{inspect(reason)}"
        })

      # The row is already gone — nothing to record the failure on.
      nil ->
        :ok
    end
  rescue
    # Recording the failure must never itself fail the fetcher.
    _ -> :ok
  end
end
