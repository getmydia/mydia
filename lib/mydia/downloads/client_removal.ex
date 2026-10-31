defmodule Mydia.Downloads.ClientRemoval do
  @moduledoc """
  Deferred Remove After Import cleanup, and which clients seed.

  Seed-aware torrent clients keep seeding until paused/completed/gone;
  other clients remove immediately when `remove_completed` is set.

  `@seed_aware` answers "does removal wait for seeding to stop", which is
  not the same as "does this client seed": rqbit seeds but has no ratio or
  time limit, so waiting would never end. `@non_seeding` answers the second
  question for import, and is an allowlist so blackhole (an unknown external
  client) and any future type keep their source.

  Before either check, a download whose tracker terms set a seeding goal
  (`Mydia.Downloads.SeedingGoal`) stays in a seed-aware client or rqbit until
  the goal is met. Manual removal is not guarded.
  """

  require Logger

  import Ecto.Query

  alias Mydia.Downloads
  alias Mydia.Downloads.Client
  alias Mydia.Downloads.Client.Error
  alias Mydia.Downloads.Client.Registry
  alias Mydia.Downloads.Download
  alias Mydia.Downloads.ObservedSeedTime
  alias Mydia.Downloads.SeedingGoal
  alias Mydia.Downloads.Structs.DownloadStatus
  alias Mydia.Repo
  alias Mydia.Settings

  @seed_aware ~w(qbittorrent transmission rtorrent)a

  def seed_aware_type?(type) when is_atom(type), do: type in @seed_aware

  @non_seeding ~w(sabnzbd nzbget debrid)a

  def non_seeding_type?(type) when is_atom(type), do: type in @non_seeding

  @doc """
  True for the clients the seeding guard applies to: the seed-aware ones and
  rqbit, which seeds without a limit of its own.
  """
  def seeding_client_type?(type) when is_atom(type), do: seed_aware_type?(type) or type == :rqbit

  @doc """
  True when the download's client never seeds, so import may consume the
  source. False when the client is unknown: keeping a file is the safe wrong
  answer.
  """
  def import_consumes_source?(%Download{download_client: name}) when is_binary(name) do
    case Enum.find(Settings.list_download_client_configs(), &(&1.name == name)) do
      %{type: type} -> non_seeding_type?(type)
      nil -> false
    end
  end

  def import_consumes_source?(%Download{}), do: false

  @job_folder_types ~w(sabnzbd nzbget)a

  @doc """
  True when the download's client writes one folder per job (SABnzbd, NZBGet).
  Debrid is excluded on purpose: its save path may be a shared output folder.
  False when the client is unknown.
  """
  def job_folder_client?(%Download{download_client: name}) when is_binary(name) do
    case Enum.find(Settings.list_download_client_configs(), &(&1.name == name)) do
      %{type: type} -> type in @job_folder_types
      nil -> false
    end
  end

  def job_folder_client?(%Download{}), do: false

  def removable_state?(state) when state in [:paused, :completed], do: true
  def removable_state?(_), do: false

  def not_found_error?(%Error{type: :not_found}), do: true
  def not_found_error?(_), do: false

  def list_pending_removals(configs \\ nil) do
    configs = configs || Settings.list_download_client_configs()

    remove_names =
      configs
      |> Enum.filter(&(&1.remove_completed || false))
      |> Enum.map(& &1.name)

    from(d in Download,
      where:
        not is_nil(d.imported_at) and is_nil(d.client_removed_at) and
          is_nil(d.removal_requested_at) and
          d.download_client in ^remove_names and
          (is_nil(d.match_status) or d.match_status != "unresolved_files")
    )
    |> Repo.all()
  end

  @doc """
  Loads client configs once and returns them with pending removal rows.

  DownloadMonitor should pass the configs into `finish_pending_removal/2`
  so each row does not re-list settings.
  """
  def finish_pending_removals do
    configs = Settings.list_download_client_configs()
    {configs, list_pending_removals(configs)}
  end

  @doc """
  Whether `download` has met its tracker's seeding goal, given the client's
  current `status`. True for a download whose frozen terms ask for nothing,
  so removal without terms behaves as before. See `Mydia.Downloads.SeedingGoal`.
  """
  @spec terms_met?(Download.t(), DownloadStatus.t() | nil) :: boolean()
  def terms_met?(%Download{} = download, status) do
    terms = SeedingGoal.terms(download)

    case status do
      %DownloadStatus{} ->
        seeding_time =
          SeedingGoal.seeding_time(
            status.seeding_time || ObservedSeedTime.seconds(download),
            status.state == :seeding,
            status.completed_at,
            download.completed_at,
            DateTime.utc_now()
          )

        SeedingGoal.met?(terms, status.ratio, seeding_time)

      nil ->
        SeedingGoal.met?(terms, nil, nil)
    end
  end

  @doc """
  Removes `download` from its client right after import when the client is
  set to Remove After Import and nothing says to wait.

  Returns `:removed`, `:skipped` (removal is off or files are unresolved),
  `:still_seeding` (the tracker's seeding goal is not met yet), `:deferred`
  (the client is missing, busy or unreadable) or `{:error, reason}`. Anything
  but `:removed` and `:skipped` leaves the row for `finish_pending_removal/2`.
  """
  def maybe_remove_after_import(%Download{match_status: "unresolved_files"}), do: :skipped

  def maybe_remove_after_import(%Download{} = download) do
    case client_info(download) do
      # Leave pending: a rename/re-add/adoption may restore the client.
      # Stamp only after remove_download :ok or a confirmed :not_found.
      {:error, :missing_client} -> missing_client(download)
      {:ok, %{remove_completed: false}} -> :skipped
      {:ok, info} -> remove_when_ready(download, info, :after_import)
    end
  end

  def finish_pending_removal(download, configs \\ nil)

  def finish_pending_removal(%Download{match_status: "unresolved_files"}, _configs),
    do: :skipped

  def finish_pending_removal(%Download{} = download, configs) do
    case client_info(download, configs) do
      {:error, :missing_client} -> missing_client(download)
      {:ok, %{remove_completed: false}} -> :skipped
      {:ok, info} -> remove_when_ready(download, info, :pending)
    end
  end

  defp missing_client(download) do
    Logger.warning("Deferring client removal; download client not found",
      download_id: download.id,
      client: download.download_client
    )

    :deferred
  end

  # The seeding guard runs before the state check, only for clients known to
  # seed (`seeding_client_type?/1`). Usenet, debrid, blackhole (an external
  # client Mydia cannot read a ratio from) and unknown types keep their
  # behaviour from before the guard.
  defp remove_when_ready(download, info, mode) do
    guarded? =
      seeding_client_type?(info.type) and SeedingGoal.applies?(SeedingGoal.terms(download))

    with {:ok, status} <- read_status(info, guarded? or seed_aware_type?(info.type)),
         :ok <- check_terms(download, status, guarded?),
         :ok <- check_state(download, info, status, mode) do
      remove_and_stamp(download, info)
    else
      :gone -> stamp_removed(download)
      {:wait, result} -> result
      {:status_error, error} -> status_error(download, error, mode)
    end
  end

  defp read_status(_info, false), do: {:ok, nil}

  defp read_status(info, true) do
    case Client.get_status(info.adapter, info.config, info.client_id) do
      {:ok, status} -> {:ok, status}
      {:error, error} -> if not_found_error?(error), do: :gone, else: {:status_error, error}
    end
  end

  defp check_terms(_download, _status, false), do: :ok

  defp check_terms(download, status, true) do
    if terms_met?(download, status) do
      :ok
    else
      Logger.info("Keeping download in client until the tracker's seeding goal is met",
        download_id: download.id
      )

      {:wait, :still_seeding}
    end
  end

  defp check_state(download, info, %{state: state}, mode) do
    cond do
      not seed_aware_type?(info.type) -> :ok
      removable_state?(state) -> :ok
      true -> {:wait, not_idle(download, state, mode)}
    end
  end

  defp check_state(_download, _info, nil, _mode), do: :ok

  defp not_idle(_download, _state, :pending), do: :still_seeding

  defp not_idle(download, :seeding, :after_import) do
    Logger.info("Deferring client removal until seeding finishes", download_id: download.id)
    :deferred
  end

  defp not_idle(download, :error, :after_import) do
    Logger.warning("Not auto-removing errored torrent after import", download_id: download.id)
    :deferred
  end

  defp not_idle(download, state, :after_import) do
    Logger.info("Deferring client removal; torrent not idle yet",
      download_id: download.id,
      state: state
    )

    :deferred
  end

  defp status_error(download, error, :after_import) do
    Logger.warning("Could not read status for post-import removal",
      download_id: download.id,
      error: inspect(error)
    )

    :deferred
  end

  defp status_error(_download, error, :pending), do: {:error, error}

  defp stamp_removed(download) do
    case stamp(download) do
      :ok -> :removed
      {:error, _} = err -> err
    end
  end

  defp client_info(%Download{} = download, configs \\ nil) do
    if download.download_client && download.download_client_id do
      configs = configs || Settings.list_download_client_configs()

      case Enum.find(configs, &(&1.name == download.download_client)) do
        nil ->
          {:error, :missing_client}

        client_config ->
          adapter = Registry.lookup(client_config.type)

          {:ok,
           %{
             type: client_config.type,
             adapter: adapter,
             config: build_client_config(client_config),
             client_id: download.download_client_id,
             remove_completed: Map.get(client_config, :remove_completed, false) || false
           }}
      end
    else
      {:error, :missing_client}
    end
  end

  defp build_client_config(client_config) do
    case client_config.type do
      :blackhole ->
        %{
          type: :blackhole,
          connection_settings: client_config.connection_settings || %{}
        }

      :debrid ->
        %{
          type: :debrid,
          api_key: client_config.api_key,
          download_directory: client_config.download_directory,
          connection_settings: client_config.connection_settings || %{}
        }

      _ ->
        %{
          type: client_config.type,
          host: client_config.host,
          port: client_config.port,
          username: client_config.username,
          password: client_config.password,
          use_ssl: client_config.use_ssl || false,
          options:
            %{}
            |> maybe_put(:url_base, client_config.url_base)
            |> maybe_put(:api_key, client_config.api_key)
        }
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp remove_and_stamp(download, info) do
    case Client.remove_download(
           info.adapter,
           info.config,
           info.client_id,
           delete_files: true
         ) do
      :ok ->
        stamp_removed(download)

      {:error, error} ->
        if not_found_error?(error), do: stamp_removed(download), else: {:error, error}
    end
  end

  defp stamp(download) do
    case Downloads.update_download(download, %{
           client_removed_at: DateTime.utc_now() |> DateTime.truncate(:second)
         }) do
      {:ok, _} ->
        :ok

      {:error, reason} = err ->
        Logger.warning("Failed to stamp client_removed_at",
          download_id: download.id,
          error: inspect(reason)
        )

        err
    end
  end
end
