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
  alias Mydia.Library.{BatchMatcher, FileIngest, ImportRun, SampleDetector, Scanner}
  alias Mydia.Metadata
  alias Mydia.{Repo, Settings}

  @scan_batch_size 100
  @match_chunk_size 50

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

        {:ok, updated} =
          Library.update_import_run(Library.get_import_run(run.id), %{
            status: :failed,
            error: inspect(reason)
          })

        broadcast(updated)
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

  ## Options

    * `:after_batch` - a 0-arity function invoked once a batch has committed,
      before the next batch's stop check. Mirrors the `:progress_callback`
      seam on `Scanner.scan/2`. Defaults to a no-op. Exists so a test can make
      the stop boundary deterministic (request the stop from inside the
      callback) instead of racing a concurrent process against the loop.
  """
  @spec run_scan_phase(ImportRun.t(), keyword()) :: :ok | :stopped | {:error, term()}
  def run_scan_phase(%ImportRun{} = run, opts \\ []) do
    after_batch = Keyword.get(opts, :after_batch, fn -> :ok end)

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
            after_batch.()
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

    current_run = Library.get_import_run(run.id)

    {:ok, updated} =
      Library.update_import_run(current_run, %{
        files_discovered: current_run.files_discovered + inserted
      })

    broadcast(updated)
  end

  ## Phase 2: match

  @doc """
  Matches outstanding files in chunks, caching a candidate for each.

  In `:unattended` mode a match at or above the confidence threshold is linked
  immediately. In `:review` mode nothing is linked from an external provider
  match, though a file whose show already exists locally is still associated:
  that needs no item creation and no human judgement.

  Returns `:ok` when no unmatched files remain, or `:stopped` if a stop was
  requested. Between chunks the run row is re-read, which is the only place a
  stop can take effect.

  ## Options

    * `:config` - metadata relay config, defaults to `Metadata.default_relay_config/0`.
      Lets a test point relay traffic at a local Bypass server without
      mutating the global `METADATA_RELAY_URL` env var (which would race any
      concurrently running async test that also resolves the default config).
    * `:after_chunk` - a 0-arity function invoked once a chunk has committed,
      before the next chunk's stop check. Mirrors the `:after_batch` seam on
      `run_scan_phase/2`, for the same reason: it makes the stop boundary
      deterministic in a test (request the stop from inside the callback)
      instead of racing a concurrent process against the loop. Defaults to a
      no-op.
  """
  @spec run_match_phase(ImportRun.t(), keyword()) :: :ok | :stopped | {:error, term()}
  def run_match_phase(%ImportRun{} = run, opts \\ []) do
    library_path = Settings.get_library_path!(run.library_path_id)
    config = Keyword.get(opts, :config) || Metadata.default_relay_config()
    after_chunk = Keyword.get(opts, :after_chunk, fn -> :ok end)

    {:ok, _} = Library.update_import_run(run, %{phase: :matching})

    match_loop(run, library_path, config, after_chunk)
  end

  defp match_loop(run, library_path, config, after_chunk) do
    if Library.import_run_stopping?(run.id) do
      :stopped
    else
      case Library.list_unmatched_media_file_paths(library_path.id, @match_chunk_size) do
        [] ->
          :ok

        chunk ->
          process_match_chunk(chunk, run, library_path, config)
          after_chunk.()
          match_loop(run, library_path, config, after_chunk)
      end
    end
  end

  defp process_match_chunk(chunk, run, library_path, config) do
    by_path = Map.new(chunk, fn {file_id, path} -> {path, file_id} end)
    policy = policy_for(run.mode)

    results =
      by_path
      |> Map.keys()
      |> BatchMatcher.match_paths(
        config: config,
        provider: library_path.tv_metadata_source,
        on_result: fn path, _result -> note_current_file(run, path) end
      )

    linked =
      results
      |> Enum.map(fn {path, result} -> ingest_result(by_path, path, result, policy, config) end)
      |> Enum.count(&(&1 == :linked))

    latest = Library.get_import_run(run.id)

    {:ok, updated} =
      Library.update_import_run(latest, %{
        files_matched: latest.files_matched + length(results),
        files_linked: latest.files_linked + linked
      })

    broadcast(updated)
  end

  defp ingest_result(by_path, path, result, policy, config) do
    file_id = Map.fetch!(by_path, path)
    media_file = Library.get_media_file!(file_id)

    match =
      case result do
        {:ok, match} -> match
        {:error, _reason} -> nil
      end

    case FileIngest.ingest(media_file, match, policy: policy, config: config) do
      {:linked, _item} -> :linked
      _ -> :matched
    end
  end

  # Review mode caches candidates and links nothing new from the relay, so the
  # human decides. Unattended mode links anything confident enough and leaves
  # the rest as a candidate.
  defp policy_for(:review), do: :local_only
  defp policy_for(:unattended), do: :create_items

  defp note_current_file(run, path) do
    Phoenix.PubSub.broadcast(
      Mydia.PubSub,
      progress_topic(run.id),
      {:import_run_current_file, Path.basename(path)}
    )
  end

  ## Progress

  defp broadcast(%ImportRun{} = run) do
    Phoenix.PubSub.broadcast(
      Mydia.PubSub,
      progress_topic(run.id),
      {:import_run_progress, run}
    )
  end
end
