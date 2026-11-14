defmodule Mydia.Jobs.MediaImport.Partial do
  @moduledoc """
  Early import: single finished files of a download that is still running.

  A partial `MediaImport` job (`"partial" => true`) places its `target_files`
  and records them in the download's `metadata["early_imported_paths"]` and
  `metadata["early_imported_episode_ids"]`. The full import at completion
  skips those paths (`exclude_early/2`) and counts those episodes when it
  checks for a partial pack. A target that fails is recorded in
  `metadata["early_import_failed_paths"]`, so `EarlyImport` stops offering it
  on every poll; the full import still processes it.

  Every `MediaImport` job carries `"partial"` and the worker is unique on
  `[:download_id, :partial]`, so a queued partial job never swallows the full
  import, and a second partial job for a download is dropped while the first
  is pending. A full import that starts while a partial job runs snoozes
  (`executing?/1`).
  """

  import Ecto.Query, warn: false

  require Logger

  alias Mydia.Downloads.{Download, MetadataKey}
  alias Mydia.Jobs.MediaImport
  alias Mydia.Jobs.MediaImport.{Args, Paths}
  alias Mydia.MediaServer.Notifier, as: MediaServerNotifier
  alias Mydia.Repo

  @worker "Mydia.Jobs.MediaImport"

  @doc """
  Enqueues a partial import of `target_files` (`[%{"path", "episode_id"}]`)
  for the download.
  """
  @spec enqueue(binary(), [map()]) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(download_id, target_files) when is_binary(download_id) and is_list(target_files) do
    changeset =
      MediaImport.new(
        %{
          "download_id" => download_id,
          "target_files" => target_files,
          "partial" => true,
          "use_hardlinks" => true
        },
        unique: [
          period: 600,
          keys: [:download_id, :partial],
          states: [:available, :scheduled, :executing, :retryable]
        ]
      )

    try do
      Oban.insert(changeset)
    rescue
      RuntimeError ->
        # In testing mode without running Oban, insert directly via Repo
        Repo.insert(changeset)
    end
  end

  @doc """
  Runs a partial job: places what can be placed and records it.

  The download is still running, so this never stamps `imported_at`, touches
  `match_status`, removes sources or the torrent, or writes failure
  bookkeeping. A file that fails here is left for the full import.
  `place_fun` is `MediaImport`'s per-target placement.
  """
  @spec run(Download.t(), Args.t(), function()) :: :ok | {:ok, :partial} | {:cancel, term()}
  def run(%{completed_at: completed_at} = download, _args, _place_fun)
      when not is_nil(completed_at) do
    Logger.info("Early import skipped: download already complete", download_id: download.id)
    :ok
  end

  def run(download, %Args{target_files: [_ | _] = targets} = args, place_fun) do
    case Paths.determine_library_path(download) do
      nil ->
        Logger.warning("Early import skipped: no library path", download_id: download.id)
        {:cancel, :no_library_path}

      library_path ->
        # The torrent is still downloading and seeding, so its files stay put.
        # The library's auto_rename decides naming, as in the full import.
        args = %{args | move_source: false, rename_files: library_path.auto_rename}
        place_all(download, targets, library_path, args, place_fun)
    end
  end

  def run(download, _args, _place_fun) do
    Logger.info("Early import skipped: no target files", download_id: download.id)
    :ok
  end

  defp place_all(download, targets, library_path, args, place_fun) do
    {placed, failed} =
      Enum.reduce(targets, {[], []}, fn target, {placed, failed} ->
        case safe_place(place_fun, download, target, library_path, args) do
          {:ok, _} -> {[target | placed], failed}
          {:error, reason} -> {placed, [{target["path"], reason} | failed]}
        end
      end)

    if failed != [] do
      Logger.warning("Early import left files for the full import",
        download_id: download.id,
        failures: inspect(Enum.reverse(failed))
      )
    end

    if placed != [] or failed != [] do
      record_early_imports(download.id, Enum.reverse(placed), Enum.map(failed, &elem(&1, 0)))
    end

    if placed != [], do: MediaServerNotifier.notify_all()

    {:ok, :partial}
  end

  # One raising file must not cost the others their placement.
  defp safe_place(place_fun, download, target, library_path, args) do
    place_fun.(download, target, library_path, args)
  rescue
    exception -> {:error, {:import_exception, Exception.message(exception)}}
  end

  # Read-merge-write under `MetadataKey`'s lock: the monitor, the built-in
  # policies and the operator's file selection write this row's metadata
  # while the download runs, and an unlocked read-modify-write here could
  # drop one of their keys. A row deleted meanwhile is skipped. Failed paths
  # are recorded so the monitor stops offering them on every poll; the full
  # import still tries.
  defp record_early_imports(download_id, placed_targets, failed_paths) do
    paths = Enum.map(placed_targets, & &1["path"])
    episode_ids = placed_targets |> Enum.map(& &1["episode_id"]) |> Enum.reject(&is_nil/1)

    result =
      MetadataKey.modify(download_id, fn metadata ->
        metadata
        |> append_uniq("early_imported_paths", paths)
        |> append_uniq("early_imported_episode_ids", episode_ids)
        |> append_uniq("early_import_failed_paths", failed_paths)
      end)

    with {:error, reason} <- result do
      Logger.warning("Failed to record early imports",
        download_id: download_id,
        reason: inspect(reason)
      )
    end
  end

  defp append_uniq(metadata, _key, []), do: metadata

  defp append_uniq(metadata, key, values) do
    Map.put(metadata, key, Enum.uniq(List.wrap(metadata[key]) ++ values))
  end

  # A partial import is a handful of hardlinks or copies. No Oban Lifeline
  # runs here, so a job orphaned in `executing` by a crash or restart stays
  # there forever; past this age it no longer holds the full import off.
  @stale_after_seconds 10 * 60

  @doc """
  True while a partial `MediaImport` job for the download is executing and
  started less than 10 minutes ago.
  """
  @spec executing?(binary()) :: boolean()
  def executing?(download_id) when is_binary(download_id) do
    cutoff = DateTime.add(DateTime.utc_now(), -@stale_after_seconds, :second)

    # The partial flag is a JSON boolean, which SQLite and Postgres extract
    # differently, so it is checked here rather than in SQL.
    from(j in Oban.Job,
      where: j.worker == @worker and j.state == "executing",
      where: j.attempted_at >= ^cutoff,
      where: ^Mydia.DB.json_equals(:args, "$.download_id", download_id),
      select: j.args
    )
    |> Repo.all()
    |> Enum.any?(&(&1["partial"] == true))
  end

  @doc """
  Drops discovered files whose path was already imported early.
  """
  @spec exclude_early([%{path: String.t()}], Download.t()) :: [%{path: String.t()}]
  def exclude_early(files, %Download{} = download) do
    case early_imported_paths(download) do
      [] ->
        files

      paths ->
        early = MapSet.new(paths)
        Enum.reject(files, &MapSet.member?(early, &1.path))
    end
  end

  @doc false
  def early_imported_paths(%Download{metadata: metadata}),
    do: List.wrap((metadata || %{})["early_imported_paths"])

  @doc false
  def early_imported_episode_ids(%Download{metadata: metadata}),
    do: List.wrap((metadata || %{})["early_imported_episode_ids"])
end
