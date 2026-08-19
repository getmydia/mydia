defmodule Mydia.Downloads.Client.Debrid.Fetcher do
  @moduledoc """
  Per-download GenServer that streams the provider's HTTPS URLs into the
  configured download directory.

  Registered under
  `{:via, Registry, {FetcherRegistry, {:debrid_fetcher, download_id}}}`, so
  duplicate `DynamicSupervisor.start_child` calls from concurrent
  `list_torrents/2` ticks receive `{:error, {:already_started, _pid}}` and
  treat it as a no-op. This is the only atomic-claim primitive needed —
  no separate ETS claim table.

  Mirrors the `Mydia.Streaming.HlsSession` / `HlsSessionSupervisor` shape:
  `DynamicSupervisor` strategy `:one_for_one` plus `restart: :temporary`,
  so a crash takes only the affected download. The next cron tick
  re-claims via the same `start_child` call.

  ## Recovery on init

  If a `.part` file exists for a file being downloaded, its on-disk size is
  used as the resume offset (not the DB `bytes_pulled` value). This ensures
  correct recovery after a mid-transfer crash regardless of when the DB was
  last updated, and avoids multi-file resume offset collisions.  The Fetcher
  always re-calls `Provider.get_download_urls/2` on restart since RD URLs are
  IP-bound and short-lived. After `@max_retries` failures, the Download is
  marked failed and the existing queue retry pipeline takes over.

  ## Retry

  On any `run/1` error, the Fetcher retries up to `@max_retries` times with
  an exponential back-off (5s, 10s, 15s). Retries clear `prefetched_urls` so
  each attempt re-resolves URLs from the provider.

  ## Jitter

  Each `Fetcher.init/1` jitters its first provider call via
  `Process.send_after(self(), :begin, :rand.uniform(@startup_jitter_max_ms))`.
  This spreads post-restart load across the per-token rate-limit budget.
  Tests inject `jitter_ms: 0` to skip the wait.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Mydia.Downloads.Client.Debrid.{Provider, RateLimiter, Shared}
  alias Mydia.Downloads.Client.Error
  alias Mydia.Downloads.{Download, History}
  alias Mydia.Repo

  @registry Mydia.Downloads.Client.Debrid.FetcherRegistry
  @supervisor Mydia.Downloads.Client.Debrid.FetcherSupervisor

  # 0-30s jitter on first call to spread post-restart load.
  @startup_jitter_max_ms 30_000

  # Retry budget for the whole fetch lifecycle (URL re-resolve + stream).
  @max_retries 3

  ## ── Public API ───────────────────────────────────────────────────────

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
    name = {:via, Registry, {@registry, {:debrid_fetcher, download_id}}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Atomically starts (or no-ops on) a Fetcher for the given Download.
  Returns `:ok` whether the Fetcher was newly started or already running.

  This is the single entry point the `Debrid` adapter uses on every
  `:ready` provider state.
  """
  @spec claim(keyword()) :: :ok | {:error, term()}
  def claim(opts) do
    case DynamicSupervisor.start_child(@supervisor, {__MODULE__, opts}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns `{:ok, pid}` if a Fetcher is registered for `download_id`,
  `:error` otherwise.
  """
  @spec whereis(binary()) :: {:ok, pid()} | :error
  def whereis(download_id) do
    case Registry.lookup(@registry, {:debrid_fetcher, download_id}) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc """
  Best-effort: terminate the Fetcher for `download_id` if one is running.
  Returns `:ok` whether or not a fetcher was registered.
  """
  @spec terminate(binary()) :: :ok
  def terminate(download_id) do
    case whereis(download_id) do
      {:ok, pid} -> DynamicSupervisor.terminate_child(@supervisor, pid)
      :error -> :ok
    end

    :ok
  end

  ## ── GenServer ────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    state = %{
      download_id: Keyword.fetch!(opts, :download_id),
      config: Keyword.fetch!(opts, :config),
      provider_job: Keyword.fetch!(opts, :provider_job),
      provider_module: Keyword.get(opts, :provider_module),
      download_dir: Keyword.get(opts, :download_dir),
      req_options: Keyword.get(opts, :req_options, []),
      jitter_ms: Keyword.get(opts, :jitter_ms, :rand.uniform(@startup_jitter_max_ms)),
      retries_left: Keyword.get(opts, :max_retries, @max_retries),
      # Pre-resolved URLs passed from the dispatch adapter on the first
      # claim. On process restart these are nil and `resolve_urls/2` falls
      # back to calling the provider, since IP-bound URLs expire.
      prefetched_urls: Keyword.get(opts, :prefetched_urls),
      finished?: false
    }

    Process.send_after(self(), :begin, state.jitter_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:begin, state) do
    case run(state) do
      {:ok, new_state} ->
        {:stop, :normal, new_state}

      # The row was deleted while we were fetching (cancelled from the UI, an
      # import that cleaned up). Terminal, and deliberately ahead of the retry
      # clause: there is nothing left to fetch for and nothing to mark failed,
      # while each retry would re-resolve provider URLs — and past `finalize/2`,
      # re-download the entire payload — against a row that is already gone
      # (issue #281).
      :download_deleted ->
        Logger.info(
          "Debrid fetcher stopping: download row no longer exists " <>
            "(download_id=#{state.download_id})"
        )

        {:stop, :normal, state}

      {:error, reason} when state.retries_left > 0 ->
        Logger.warning(
          "Debrid fetcher attempt failed for download_id=#{state.download_id} " <>
            "(#{state.retries_left} retries left): #{inspect(reason)}"
        )

        retry_ms = (@max_retries - state.retries_left + 1) * 5_000
        Process.send_after(self(), :begin, retry_ms)
        {:noreply, %{state | retries_left: state.retries_left - 1}}

      {:error, reason} ->
        fail_download(state, reason)
        {:stop, :normal, state}
    end
  end

  ## ── Run flow ─────────────────────────────────────────────────────────

  defp run(state) do
    with {:ok, provider_module} <- resolve_provider_module(state),
         {:ok, {urls_or_descriptors, state}} <- resolve_urls(provider_module, state),
         {:ok, urls} <- prepare_urls(urls_or_descriptors, state),
         {:ok, download} <- persist_urls(urls_or_descriptors, state),
         download_dir <- download_dir!(state),
         :ok <- File.mkdir_p(download_dir) do
      stream_all(urls, download_dir, %{state | provider_module: provider_module}, download)
    end
  end

  defp resolve_provider_module(%{provider_module: mod}) when not is_nil(mod), do: {:ok, mod}

  defp resolve_provider_module(%{config: config}) do
    with {:ok, key} <- Provider.provider_key(config), do: Provider.module_for(key)
  end

  defp resolve_urls(_provider_module, %{prefetched_urls: prefetched} = state)
       when is_list(prefetched) and prefetched != [] do
    # First run: use the URLs already resolved by the dispatch adapter to
    # avoid doubling the /unrestrict/link (or equivalent) call count.
    # Clear prefetched_urls so that a retry uses a fresh provider call.
    {:ok, {prefetched, %{state | prefetched_urls: nil}}}
  end

  defp resolve_urls(provider_module, state) do
    %{config: config, provider_job: job} = state
    provider_atom = provider_atom(provider_module)
    {budget_req, budget_window} = provider_module.rate_limit_budget()

    case RateLimiter.acquire(
           provider_atom,
           config[:api_key] || config.api_key,
           {budget_req, budget_window}
         ) do
      :ok ->
        case provider_module.get_download_urls(config, job) do
          {:ok, urls} -> {:ok, {urls, state}}
          {:error, _} = err -> err
        end

      {:error, :rate_limited} ->
        {:error,
         Error.api_error("rate-limited by debrid provider", %{
           reason: :rate_limited,
           provider: provider_atom
         })}
    end
  end

  defp prepare_urls(urls_or_descriptors, state) do
    urls_or_descriptors
    |> Enum.reduce_while([], fn entry, acc ->
      case to_http_url(entry, state.config) do
        {:ok, url} ->
          case Shared.validate_download_url(url) do
            {:ok, validated} -> {:cont, [validated | acc]}
            {:error, _} = err -> {:halt, err}
          end

        {:descriptor, descriptor} ->
          # TorBox descriptors: validation happens at request time after
          # token reconstruction. We still validate the eventual URL there.
          {:cont, [{:descriptor, descriptor} | acc]}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
    |> case do
      {:error, _} = err -> err
      list when is_list(list) -> {:ok, Enum.reverse(list)}
    end
  end

  defp to_http_url(url, _config) when is_binary(url), do: {:ok, url}

  defp to_http_url(%{"provider" => "torbox"} = descriptor, _config) do
    # Token reconstruction happens just before the HTTP call so the token
    # never sits in the in-memory URL list — TorBox provider builds the
    # `requestdl?...&redirect=true&token=...` URL there.
    {:descriptor, descriptor}
  end

  defp to_http_url(other, _config),
    do: {:error, Error.api_error("unrecognised debrid URL/descriptor", %{entry: inspect(other)})}

  defp persist_urls(urls_or_descriptors, state) do
    persisted =
      Enum.map(urls_or_descriptors, fn
        url when is_binary(url) ->
          %{
            "url" => url,
            "resolved_at" => DateTime.utc_now() |> DateTime.to_iso8601()
          }

        %{"provider" => _} = descriptor ->
          descriptor
      end)

    case History.get_download(state.download_id) do
      # Cancelled or deleted while we were resolving (issue #281). Terminal, not
      # an error: see the `:download_deleted` clause in `handle_info/2`.
      nil -> :download_deleted
      download -> persist_metadata(download, %{"debrid_urls" => persisted})
    end
  end

  # Writes `attrs` into the row's metadata, collapsing "the row was deleted
  # between the lookup above and this write" into the same terminal
  # `:download_deleted` the nil lookup returns. Same race, narrower window, and
  # retrying it is just as pointless (issue #281). An ordinary changeset error
  # still surfaces as `{:error, _}` and stays retryable.
  defp persist_metadata(download, attrs) do
    case History.update_download(download, %{
           metadata: Map.merge(download.metadata || %{}, attrs)
         }) do
      {:error, %Ecto.Changeset{} = changeset} ->
        if History.stale_changeset?(changeset),
          do: :download_deleted,
          else: {:error, changeset}

      ok ->
        ok
    end
  end

  defp stream_all(urls, download_dir, state, download) do
    with {:ok, state} <- stream_each(urls, download_dir, state, download) do
      finalize(download_dir, state)
    end
  end

  defp stream_each([], _download_dir, state, _download), do: {:ok, state}

  defp stream_each([entry | rest], download_dir, state, download) do
    {url_for_request, name_hint} = http_url_and_name(entry, state)

    final_name = filename_for(name_hint, state, download)
    final_path = Path.join(download_dir, final_name)
    part_path = final_path <> ".part"

    case stream_one(url_for_request, part_path, final_path, state, download) do
      {:ok, state} -> stream_each(rest, download_dir, state, download)
      {:error, _} = err -> err
    end
  end

  defp http_url_and_name(entry, _state) when is_binary(entry) do
    # URL-decode the basename so URI-encoded characters (`%20` for space,
    # `%5B` for `[`, etc.) become real filename characters. Otherwise the
    # MediaImport file parser sees "Project%20Hail%20Mary.mkv" and fails
    # title detection that depends on the file's natural-language tokens.
    name =
      entry
      |> URI.parse()
      |> Map.get(:path)
      |> Kernel.||("debrid-file")
      |> Path.basename()
      |> URI.decode()

    {entry, name}
  end

  defp http_url_and_name({:descriptor, descriptor}, state) do
    # TorBox: provider module must materialize the URL. The descriptor
    # carries `torrent_id` + `file_id`. The provider's
    # `materialize_descriptor/2` reconstructs `requestdl?token=...`.
    case state.provider_module do
      mod when not is_nil(mod) ->
        case apply_optional(mod, :materialize_descriptor, [state.config, descriptor]) do
          {:ok, url} ->
            name = "torbox-#{descriptor["torrent_id"]}-#{descriptor["file_id"]}.bin"
            {url, name}

          _ ->
            raise "provider module #{inspect(mod)} did not materialize TorBox descriptor"
        end

      _ ->
        raise "no provider module available to materialize descriptor"
    end
  end

  defp apply_optional(module, fun, args) do
    if function_exported?(module, fun, length(args)) do
      apply(module, fun, args)
    else
      {:error, :not_exported}
    end
  end

  defp filename_for(hint, _state, _download), do: hint

  defp stream_one(url_or_descriptor, part_path, final_path, state, download) do
    with {:ok, url} <- maybe_validate_url(url_or_descriptor),
         {:ok, offset} <- prepare_part(part_path, download, state),
         {:ok, _bytes} <- fetch_into(url, part_path, offset, state) do
      :ok = File.rename(part_path, final_path)
      {:ok, %{state | finished?: true}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_validate_url(url) when is_binary(url), do: Shared.validate_download_url(url)

  defp prepare_part(part_path, _download, state) do
    if File.exists?(part_path) do
      actual_size = byte_size_of(part_path)

      if actual_size > 0 do
        # Sync bytes_pulled to the real file size so crash-recovery uses
        # the correct Range offset, regardless of what the DB row says.
        # This also correctly handles multi-file releases: each file has
        # its own `.part` path, so `actual_size` is the offset for *this*
        # file, not a previous one.
        update_bytes_pulled(state.download_id, actual_size)
        {:ok, actual_size}
      else
        {:ok, 0}
      end
    else
      :ok = File.touch(part_path)
      # Reset bytes_pulled to 0 when starting a fresh file so that a
      # previous completed file's byte count doesn't pollute progress
      # reporting or recovery for the next file in a multi-file release.
      update_bytes_pulled(state.download_id, 0)
      {:ok, 0}
    end
  end

  defp fetch_into(url, part_path, offset, state) do
    headers =
      if offset > 0 do
        [{"range", "bytes=#{offset}-"}]
      else
        []
      end

    req_opts =
      Keyword.merge(
        [url: url, headers: headers, into: File.stream!(part_path, [:append, :raw])],
        state.req_options
      )

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: 206}} ->
        update_bytes_pulled(state.download_id, byte_size_of(part_path))
        {:ok, byte_size_of(part_path)}

      {:ok, %Req.Response{status: 200}} ->
        if offset > 0 do
          # Server ignored the range header — restart from byte 0.
          File.rm!(part_path)
          File.touch!(part_path)
          update_bytes_pulled(state.download_id, 0)
          fetch_into(url, part_path, 0, state)
        else
          update_bytes_pulled(state.download_id, byte_size_of(part_path))
          {:ok, byte_size_of(part_path)}
        end

      {:ok, %Req.Response{} = resp} ->
        {:error,
         Error.from_req_error(%Req.Response{
           resp
           | body: Shared.sanitize_error_body(resp.body, state.config)
         })}

      {:error, %Req.TransportError{} = err} ->
        {:error, Error.from_req_error(err)}

      {:error, other} ->
        {:error, Error.unknown("Req failure: #{inspect(other)}")}
    end
  end

  defp byte_size_of(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: s}} -> s
      _ -> 0
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

  defp finalize(_download_dir, state) do
    # Update Download.metadata["save_path"] to point at the download directory.
    # The existing MediaImport pipeline picks the file up from there.
    #
    # NOTE: do NOT set Download.completed_at here. The DownloadMonitor cron
    # uses `is_nil(d.db_completed_at)` as the "newly completed → enqueue
    # MediaImport" trigger (see download_monitor.ex's `completed` filter).
    # If the Fetcher sets completed_at itself, the cron skips this row
    # forever and the file sits in staging without ever being imported.
    # The cron's `handle_completed_download/2` is what should stamp
    # completed_at — right before it enqueues the import job.
    case History.get_download(state.download_id) do
      # Cancelled or deleted while the payload was streaming (issue #281). There
      # is no row left to point at the staging directory. Terminal rather than
      # an error, because this runs *after* the whole payload has transferred:
      # a retry would re-resolve provider URLs and download all of it again.
      nil ->
        :download_deleted

      download ->
        case persist_metadata(download, %{"save_path" => download_dir!(state)}) do
          {:ok, _} -> {:ok, state}
          :download_deleted -> :download_deleted
          {:error, cs} -> {:error, Error.unknown("failed to finalize download: #{inspect(cs)}")}
        end
    end
  end

  defp download_dir!(state) do
    base =
      cond do
        is_binary(state.download_dir) and state.download_dir != "" ->
          state.download_dir

        is_binary(state.config[:download_directory]) and state.config[:download_directory] != "" ->
          state.config[:download_directory]

        true ->
          default_download_root()
      end

    Path.join(base, state.download_id)
  end

  # Picks the operator-conventional download root. In the production Docker
  # image the LSIO volume `/data` is mounted and writable (see the project
  # Dockerfile's `VOLUME ["/config", "/data", "/media"]`); falling back to
  # `System.tmp_dir!()` covers dev, tests, and non-Docker installs.
  defp default_download_root do
    if writable_dir?("/data") do
      "/data/debrid-downloads"
    else
      Path.join(System.tmp_dir!(), "mydia-debrid-downloads")
    end
  end

  defp writable_dir?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :directory, access: access}} when access in [:write, :read_write] ->
        true

      _ ->
        false
    end
  end

  defp provider_atom(module) do
    case module do
      Mydia.Downloads.Client.Debrid.Providers.RealDebrid -> :real_debrid
      Mydia.Downloads.Client.Debrid.Providers.AllDebrid -> :all_debrid
      Mydia.Downloads.Client.Debrid.Providers.Premiumize -> :premiumize
      Mydia.Downloads.Client.Debrid.Providers.TorBox -> :tor_box
      _ -> :unknown
    end
  end

  defp fail_download(state, %Error{} = error) do
    Logger.warning(
      "Debrid fetcher failed for download_id=#{state.download_id}: #{Error.message(error)}"
    )

    case History.get_download(state.download_id) do
      %Download{} = d ->
        History.update_download(d, %{
          import_failed_at: DateTime.utc_now(),
          import_last_error: "fetch_failed: #{Error.message(error)}"
        })

      # The row is already gone — nothing to record the failure on.
      nil ->
        :ok
    end
  rescue
    # Recording the failure must never itself fail the fetcher.
    _ -> :ok
  end

  defp fail_download(state, reason) do
    fail_download(state, Error.unknown("fetcher failed: #{inspect(reason)}"))
  end
end
