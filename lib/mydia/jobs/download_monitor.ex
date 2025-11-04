defmodule Mydia.Jobs.DownloadMonitor do
  @moduledoc """
  Background job for monitoring active downloads.

  This job:
  - Checks status of active downloads from download clients
  - Updates download progress and ETA
  - Handles download completion and import
  - Retries failed downloads based on configured rules
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 5

  require Logger
  alias Mydia.Downloads
  alias Mydia.Downloads.Client
  alias Mydia.Settings

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    Logger.info("Starting download monitoring", args: args)

    # Get configured download clients
    download_clients = get_configured_clients()

    if download_clients == [] do
      Logger.warning("No download clients configured, skipping monitoring")
      :ok
    else
      # Get all active downloads (pending or downloading)
      active_downloads = Downloads.list_active_downloads(preload: [:media_item, :episode])

      Logger.info("Found #{length(active_downloads)} active downloads")

      # Monitor each download
      results =
        Enum.map(active_downloads, fn download ->
          monitor_download(download, download_clients)
        end)

      # Count results
      {success_count, error_count} =
        Enum.reduce(results, {0, 0}, fn
          :ok, {ok, err} -> {ok + 1, err}
          {:error, _}, {ok, err} -> {ok, err + 1}
        end)

      Logger.info("Download monitoring completed",
        total: length(active_downloads),
        success: success_count,
        errors: error_count
      )

      :ok
    end
  end

  ## Private Functions

  defp get_configured_clients do
    runtime_config = Settings.get_runtime_config()

    if is_struct(runtime_config) and Map.has_key?(runtime_config, :download_clients) do
      runtime_config.download_clients
      |> Enum.filter(& &1.enabled)
      |> Enum.sort_by(& &1.priority)
    else
      []
    end
  end

  defp monitor_download(download, _clients) when is_nil(download.download_client) do
    Logger.debug("Download has no assigned client, skipping",
      download_id: download.id,
      title: download.title
    )

    :ok
  end

  defp monitor_download(download, clients) do
    Logger.debug("Monitoring download",
      download_id: download.id,
      title: download.title,
      client: download.download_client,
      client_id: download.download_client_id
    )

    # Find the configured client
    client_config = Enum.find(clients, &(&1.name == download.download_client))

    if client_config do
      monitor_download_with_client(download, client_config)
    else
      Logger.warning("Download client not found in configuration",
        download_id: download.id,
        client_name: download.download_client
      )

      {:error, :client_not_found}
    end
  end

  defp monitor_download_with_client(download, client_config) do
    # Get the appropriate adapter module
    adapter = get_adapter_module(client_config.type)

    if adapter do
      # Build client configuration map
      config = build_client_config(client_config)

      # Query the download client for status
      case Client.get_status(adapter, config, download.download_client_id) do
        {:ok, status} ->
          handle_status_update(download, status)

        {:error, %Client.Error{type: :not_found}} ->
          Logger.warning("Download not found in client",
            download_id: download.id,
            client_id: download.download_client_id
          )

          # Mark as failed since it's not in the client anymore
          Downloads.fail_download(download, "Download not found in client")
          {:error, :not_found}

        {:error, error} ->
          Logger.error("Failed to get download status",
            download_id: download.id,
            client: download.download_client,
            error: inspect(error)
          )

          # Don't fail the download on transient errors
          {:error, :client_error}
      end
    else
      Logger.error("Unknown client adapter type",
        download_id: download.id,
        client_type: client_config.type
      )

      {:error, :unknown_adapter}
    end
  end

  defp handle_status_update(download, status) do
    Logger.debug("Received status update",
      download_id: download.id,
      state: status.state,
      progress: status.progress_percent
    )

    case status.state do
      :completed ->
        handle_completed_download(download, status)

      :error ->
        error_message = status.error_message || "Download failed in client"
        Downloads.fail_download(download, error_message)
        :ok

      state when state in [:downloading, :seeding, :paused, :checking] ->
        update_download_progress(download, status)

      _other ->
        Logger.debug("Download in state #{status.state}, no action needed",
          download_id: download.id
        )

        :ok
    end
  end

  defp handle_completed_download(download, status) do
    Logger.info("Download completed",
      download_id: download.id,
      title: download.title,
      save_path: status.save_path
    )

    # Mark as completed in database
    case Downloads.complete_download(download) do
      {:ok, updated} ->
        # Trigger media library import workflow
        Logger.info("Download marked as completed, enqueuing import job",
          download_id: download.id,
          save_path: status.save_path
        )

        # Enqueue import job
        case enqueue_import_job(updated) do
          {:ok, _job} ->
            Logger.info("Import job enqueued", download_id: updated.id)
            :ok

          {:error, reason} ->
            Logger.error("Failed to enqueue import job",
              download_id: updated.id,
              reason: inspect(reason)
            )

            {:error, :import_job_failed}
        end

      {:error, changeset} ->
        Logger.error("Failed to mark download as completed",
          download_id: download.id,
          errors: inspect(changeset.errors)
        )

        {:error, :update_failed}
    end
  end

  defp enqueue_import_job(download) do
    %{
      "download_id" => download.id,
      "cleanup_client" => true,
      "move_files" => false
    }
    |> Mydia.Jobs.MediaImport.new()
    |> Oban.insert()
  end

  defp update_download_progress(download, status) do
    # Calculate ETA if we have download speed and size info
    estimated_completion = calculate_eta(status)

    # Only update if progress has changed significantly (to reduce DB writes)
    if should_update_progress?(download, status.progress_percent) do
      Logger.debug("Updating download progress",
        download_id: download.id,
        old_progress: download.progress,
        new_progress: status.progress_percent
      )

      # Build metadata with speed and size information
      metadata =
        (download.metadata || %{})
        |> Map.merge(build_metadata_from_status(status))

      attrs = %{
        progress: status.progress_percent,
        estimated_completion: estimated_completion,
        metadata: metadata,
        status: if(status.state == :downloading, do: "downloading", else: download.status)
      }

      case Downloads.update_download(download, attrs) do
        {:ok, _updated} ->
          :ok

        {:error, changeset} ->
          Logger.error("Failed to update download progress",
            download_id: download.id,
            errors: inspect(changeset.errors)
          )

          {:error, :update_failed}
      end
    else
      :ok
    end
  end

  defp build_metadata_from_status(status) do
    %{
      download_speed: status.download_speed,
      upload_speed: status.upload_speed,
      size: status.size,
      downloaded: status.downloaded,
      uploaded: status.uploaded,
      seeders: status.seeders,
      leechers: status.leechers,
      ratio: status.ratio,
      last_updated: DateTime.utc_now()
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp should_update_progress?(download, new_progress) do
    # Update if:
    # - No previous progress recorded
    # - Progress changed by more than 1%
    # - Progress reached 100%
    is_nil(download.progress) or
      abs((download.progress || 0) - new_progress) >= 1.0 or
      new_progress >= 100.0
  end

  defp calculate_eta(status) do
    # If we have ETA from the client, convert it to a datetime
    cond do
      status.eta && status.eta > 0 ->
        DateTime.add(DateTime.utc_now(), status.eta, :second)

      # If we have download speed and bytes remaining, calculate ETA
      status.download_speed && status.download_speed > 0 && status.size && status.downloaded ->
        remaining_bytes = status.size - status.downloaded
        eta_seconds = div(remaining_bytes, status.download_speed)
        DateTime.add(DateTime.utc_now(), eta_seconds, :second)

      true ->
        nil
    end
  end

  defp get_adapter_module(:qbittorrent), do: Mydia.Downloads.Client.Qbittorrent
  defp get_adapter_module(:transmission), do: Mydia.Downloads.Client.Transmission
  defp get_adapter_module(:http), do: Mydia.Downloads.Client.HTTP
  defp get_adapter_module(_), do: nil

  defp build_client_config(client_config) do
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

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
