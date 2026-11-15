defmodule Mydia.Downloads.EarlyImport do
  @moduledoc """
  Early import: enqueue partial `MediaImport` jobs for finished files of a
  multi-file download that is still running.

  `DownloadMonitor` calls `run/1` on each poll. The monitor's list comes from
  the client's list endpoint, which for rqbit carries no per-file progress, so
  `run/1` fetches a fresh status for each candidate (a download with recorded
  `metadata["file_episodes"]`). `ready_targets/3` judges the struct as given,
  with the existence check and the path mapping passed in.
  """

  require Logger

  alias Mydia.Downloads.Client
  alias Mydia.Downloads.Queue.ClientSelection
  alias Mydia.Downloads.Structs.EnrichedDownload
  alias Mydia.Jobs.MediaImport.Partial
  alias Mydia.Library.PathMapping

  @type target :: %{String.t() => String.t()}

  @doc """
  Files of the download that can be imported now: complete, with a recorded
  single episode, present on this host and neither early imported nor failed
  an early import before (the full import retries those).

  Paths go through `map_path` (the configured path mappings, as the full
  import's discovery applies them) before the existence check, and the mapped
  path is what a target carries, so `Partial.exclude_early/2` sees the path
  the full import discovers.
  """
  @spec ready_targets(
          EnrichedDownload.t(),
          (String.t() -> boolean()),
          (String.t() -> String.t())
        ) :: [target()]
  def ready_targets(download, exists? \\ &File.exists?/1, map_path \\ &PathMapping.rewrite/1)

  def ready_targets(
        %EnrichedDownload{status: "downloading", file_progress: [_, _ | _] = progress} = d,
        exists?,
        map_path
      ) do
    metadata = d.metadata || %{}
    episodes = metadata["file_episodes"] || %{}

    skip =
      List.wrap(metadata["early_imported_paths"]) ++
        List.wrap(metadata["early_import_failed_paths"])

    for entry <- progress,
        entry.have == entry.length,
        episode_id = Map.get(episodes, Integer.to_string(entry.index)),
        path = map_path.(entry.path),
        path not in skip,
        exists?.(path) do
      %{"path" => path, "episode_id" => episode_id}
    end
  end

  def ready_targets(_download, _exists?, _map_path), do: []

  @doc """
  Enqueues a partial import for each download with ready files. Never raises.
  """
  @spec run([EnrichedDownload.t()]) :: :ok
  def run(downloads) do
    downloads
    |> Enum.filter(&candidate?/1)
    |> Enum.each(&run_one/1)
  end

  defp candidate?(%EnrichedDownload{status: "downloading", metadata: %{"file_episodes" => fe}})
       when is_map(fe) and map_size(fe) > 0,
       do: true

  defp candidate?(_), do: false

  defp run_one(download) do
    with {:ok, download} <- with_file_progress(download),
         [_ | _] = targets <- ready_targets(download),
         {:ok, _job} <- Partial.enqueue(download.id, targets) do
      :ok
    else
      [] ->
        :ok

      {:error, reason} ->
        Logger.debug("Early import skipped", download_id: download.id, reason: inspect(reason))

      other ->
        Logger.debug("Early import skipped", download_id: download.id, reason: inspect(other))
    end
  rescue
    error ->
      Logger.warning(
        "Early import failed for download #{download.id}: #{Exception.message(error)}"
      )
  catch
    kind, reason ->
      Logger.warning(
        "Early import failed for download #{download.id}: #{inspect({kind, reason})}"
      )
  end

  defp with_file_progress(%EnrichedDownload{file_progress: progress} = d) when is_list(progress),
    do: {:ok, d}

  defp with_file_progress(download) do
    with {:ok, adapter, config} <- ClientSelection.resolve_adapter(download.download_client),
         {:ok, status} <- Client.get_status(adapter, config, download.download_client_id) do
      {:ok, %{download | file_progress: Map.get(status, :file_progress)}}
    end
  end
end
