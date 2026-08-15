defmodule Mydia.Jobs.ImportRun do
  @moduledoc """
  Coordinates one user-started import of a library path.

  Two phases. Phase 1 walks the tree and commits a `media_file` row for every
  file found, in transactions of 100. It does no HTTP, so it is fast, and once
  it has run every file on disk is durably recorded. Phase 2 matches the
  outstanding files against the metadata provider in chunks, caching a
  candidate for each and, in unattended mode, linking the confident ones.

  Stopping is cooperative. Stop writes `:stopping` to the run row; the
  coordinator re-reads that row between chunks and drains. Nothing is rolled
  back, because every unit of work was committed as it completed.

  There is no resume cursor. A later run rediscovers the outstanding work by
  querying for it: phase 1 skips paths that already have rows, and phase 2
  skips files that already have a candidate or a parent. The database is the
  cursor.
  """

  use Oban.Worker,
    queue: :imports,
    max_attempts: 3,
    unique: [
      period: :infinity,
      states: [:available, :scheduled, :executing, :retryable, :suspended],
      keys: [:import_run_id]
    ]

  require Logger

  alias Mydia.Library
  alias Mydia.Library.{ImportRun, SampleDetector, Scanner}
  alias Mydia.{Repo, Settings}

  @scan_batch_size 100

  @doc """
  PubSub topic carrying progress for one run.
  """
  @spec progress_topic(binary()) :: String.t()
  def progress_topic(run_id), do: "import_run:#{run_id}"

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"import_run_id" => run_id}}) do
    case Library.get_import_run(run_id) do
      nil ->
        Logger.warning("Import run vanished before it could execute", import_run_id: run_id)
        :ok

      run ->
        execute(run)
    end
  end

  defp execute(run) do
    with :ok <- run_scan_phase(run),
         :ok <- run_match_phase(Library.get_import_run(run.id)) do
      finish(run, :done)
    else
      :stopped ->
        finish(run, :stopped)

      {:error, reason} ->
        Logger.error("Import run failed",
          import_run_id: run.id,
          reason: inspect(reason)
        )

        Library.update_import_run(run, %{status: :failed, error: inspect(reason)})
        {:error, reason}
    end
  end

  defp finish(run, status) do
    {:ok, updated} =
      Library.update_import_run(Library.get_import_run(run.id), %{
        status: status,
        phase: :finished,
        current_file: nil
      })

    broadcast(updated)
    :ok
  end

  ## Phase 1: scan

  @doc """
  Walks the library path and commits a `media_file` row per discovered file.

  Returns `:ok` when the whole tree was scanned, or `:stopped` if a stop was
  requested partway through. A partial scan is valid state, not an error.
  """
  @spec run_scan_phase(ImportRun.t()) :: :ok | :stopped | {:error, term()}
  def run_scan_phase(%ImportRun{} = run) do
    library_path = Settings.get_library_path!(run.library_path_id)
    extensions = Scanner.extensions_for_library_type(library_path.type)

    {:ok, _} = Library.update_import_run(run, %{phase: :scanning})

    case Scanner.scan(library_path.path, video_extensions: extensions) do
      {:ok, scan_result} ->
        scan_result.files
        |> Enum.reject(&sample_or_extra?/1)
        |> Enum.chunk_every(@scan_batch_size)
        |> Enum.reduce_while(:ok, fn batch, _acc ->
          if Library.import_run_stopping?(run.id) do
            {:halt, :stopped}
          else
            insert_batch(batch, library_path, run)
            {:cont, :ok}
          end
        end)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp sample_or_extra?(file_info) do
    not SampleDetector.skip_detection?(file_info.path) and
      SampleDetector.excluded?(SampleDetector.detect(file_info.path))
  end

  defp insert_batch(batch, library_path, run) do
    {:ok, inserted} =
      Repo.transaction(fn ->
        Enum.count(batch, fn file_info ->
          relative_path = Path.relative_to(file_info.path, library_path.path)

          case Library.get_media_file_by_relative_path(library_path.id, relative_path,
                 include_trashed: true
               ) do
            nil ->
              case Library.create_scanned_media_file(%{
                     library_path_id: library_path.id,
                     relative_path: relative_path,
                     size: file_info.size,
                     verified_at: DateTime.utc_now()
                   }) do
                {:ok, _} -> true
                {:error, _} -> false
              end

            %{trashed_at: trashed_at} = trashed when not is_nil(trashed_at) ->
              match?({:ok, _}, Library.restore_media_file(trashed))

            _existing ->
              # Already recorded by an earlier run. This is the resume path.
              false
          end
        end)
      end)

    {:ok, updated} =
      Library.update_import_run(Library.get_import_run(run.id), %{
        files_discovered: Library.get_import_run(run.id).files_discovered + inserted
      })

    broadcast(updated)
  end

  ## Phase 2 lands in the next task.

  @doc false
  def run_match_phase(%ImportRun{}), do: :ok

  ## Progress

  defp broadcast(%ImportRun{} = run) do
    Phoenix.PubSub.broadcast(
      Mydia.PubSub,
      progress_topic(run.id),
      {:import_run_progress, run}
    )
  end
end
