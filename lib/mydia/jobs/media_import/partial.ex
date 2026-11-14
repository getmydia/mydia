defmodule Mydia.Jobs.MediaImport.Partial do
  @moduledoc """
  Early import: single finished files of a download that is still running.

  A partial `MediaImport` job (`"partial" => true`) places its `target_files`
  and records them in the download's `metadata["early_imported_paths"]` and
  `metadata["early_imported_episode_ids"]`. The full import at completion
  skips those paths (`exclude_early/2`) and counts those episodes when it
  checks for a partial pack.

  Every `MediaImport` job carries `"partial"` and the worker is unique on
  `[:download_id, :partial]`, so a queued partial job never swallows the full
  import, and a second partial job for a download is dropped while the first
  is pending. A full import that starts while a partial job runs snoozes
  (`executing?/1`).
  """

  import Ecto.Query, warn: false

  alias Mydia.Downloads.Download
  alias Mydia.Jobs.MediaImport
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
  True while a partial `MediaImport` job for the download is executing.
  """
  @spec executing?(binary()) :: boolean()
  def executing?(download_id) when is_binary(download_id) do
    # The partial flag is a JSON boolean, which SQLite and Postgres extract
    # differently, so it is checked here rather than in SQL.
    from(j in Oban.Job,
      where: j.worker == @worker and j.state == "executing",
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
