defmodule Mydia.Jobs.FileAnalysis do
  @moduledoc """
  Recurring worker that fills in tech metadata for `MediaFile` rows the
  import path leaves at `analyzed_at IS NULL`, then uses spare capacity to
  repair legacy analyzed rows that are missing persisted dimensions.

  Selection is by row state, so the worker is naturally idempotent: every
  tick pulls a bounded batch of un-analyzed rows whose `analysis_attempts`
  is below the ceiling, runs ffprobe, and routes the write through
  `Mydia.Library.apply_analysis/2`. The write is guarded by
  `WHERE analyzed_at IS NULL`, so concurrent writers (this worker, the
  lazy on-play fallback, the operator retry) never clobber a fresher
  result.

  ## Configuration

      config :mydia, :file_analysis_batch_size, 50
      config :mydia, :file_analysis_max_attempts, 3

  Both default to the module attributes below. The Oban queue concurrency
  is configured separately via `config :mydia, Oban`.
  """

  use Oban.Worker,
    queue: :analysis,
    max_attempts: 3,
    # Prevent cron pileup when a batch overruns the 1-minute tick. Two ticks
    # concurrently selecting the same `analyzed_at IS NULL` rows would run
    # ffprobe twice on the same files; the apply_analysis WHERE guard
    # protects the write but not the wasted work. :retryable is included
    # because this worker runs up to 3 attempts — a failed analysis pass
    # sitting in :retryable must still block a duplicate insert, otherwise a
    # second tick starts ffprobing the same files while the first is backing
    # off before its next attempt.
    unique: [
      period: 60,
      fields: [:worker],
      states: [:suspended, :available, :scheduled, :executing, :retryable]
    ]

  import Ecto.Query
  import Mydia.DB

  require Logger

  alias Mydia.Library
  alias Mydia.Library.{FileAnalyzer, MediaFile}
  alias Mydia.Library.Structs.FileMetadata
  alias Mydia.Repo

  @default_batch_size 50
  @default_max_attempts 3

  @spec perform(Oban.Job.t()) :: :ok
  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    batch_size = Application.get_env(:mydia, :file_analysis_batch_size, @default_batch_size)
    max_attempts = Application.get_env(:mydia, :file_analysis_max_attempts, @default_max_attempts)

    analyze_rows = fetch_unanalyzed_rows(batch_size, max_attempts)
    remaining_slots = max(batch_size - length(analyze_rows), 0)

    repair_rows =
      fetch_repair_rows(remaining_slots, max_attempts, Enum.map(analyze_rows, & &1.id))

    rows = Enum.map(analyze_rows, &{:analyze, &1}) ++ Enum.map(repair_rows, &{:repair, &1})

    case rows do
      [] ->
        :ok

      rows ->
        Logger.debug("FileAnalysis worker processing batch", count: length(rows))

        Enum.each(rows, &process_row/1)

        :ok
    end
  end

  defp fetch_unanalyzed_rows(batch_size, max_attempts) do
    from(mf in MediaFile,
      where: is_nil(mf.analyzed_at) and mf.analysis_attempts < ^max_attempts,
      order_by: [asc: mf.inserted_at],
      limit: ^batch_size,
      preload: :library_path
    )
    |> Repo.all()
  end

  defp fetch_repair_rows(0, _max_attempts, _exclude_ids), do: []

  defp fetch_repair_rows(limit, max_attempts, exclude_ids) do
    overscan_limit = max(limit * 5, 20)

    from(mf in MediaFile,
      where:
        not is_nil(mf.analyzed_at) and is_nil(mf.trashed_at) and
          mf.analysis_attempts < ^max_attempts and
          not is_nil(mf.codec) and not is_nil(mf.resolution) and
          (is_nil(json_extract(mf.metadata, "$.width")) or
             is_nil(json_extract(mf.metadata, "$.height"))) and
          mf.id not in ^exclude_ids,
      order_by: [asc: mf.updated_at, asc: mf.id],
      limit: ^overscan_limit,
      preload: :library_path
    )
    |> Repo.all()
    |> Enum.filter(&repair_candidate?/1)
    |> Enum.take(limit)
  end

  defp repair_candidate?(%MediaFile{metadata: %FileMetadata{} = metadata}) do
    is_nil(metadata.width) or is_nil(metadata.height)
  end

  defp repair_candidate?(_), do: false

  defp process_row({:analyze, media_file}), do: analyze_one(media_file)
  defp process_row({:repair, media_file}), do: repair_one(media_file)

  defp analyze_one(%MediaFile{} = media_file) do
    case MediaFile.absolute_path(media_file) do
      nil ->
        Library.apply_analysis(media_file, {:error, :path_not_resolved})

        Logger.warning("Skipping analysis: media file path could not be resolved",
          file_id: media_file.id
        )

      absolute_path ->
        result = FileAnalyzer.analyze(absolute_path)
        outcome = Library.apply_analysis(media_file, result)
        log_outcome(media_file, absolute_path, result, outcome)
    end

    :ok
  end

  defp repair_one(%MediaFile{} = media_file) do
    case Library.repair_file_metadata(media_file) do
      {:ok, _updated} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to repair media file metadata",
          file_id: media_file.id,
          reason: inspect(reason)
        )
    end

    :ok
  end

  defp log_outcome(media_file, path, {:ok, _}, :ok) do
    Logger.info("Analyzed media file",
      file_id: media_file.id,
      path: path
    )
  end

  defp log_outcome(_media_file, _path, {:ok, _}, :already_analyzed), do: :ok

  defp log_outcome(media_file, path, {:error, reason}, _outcome) do
    Logger.warning("Failed to analyze media file",
      file_id: media_file.id,
      path: path,
      reason: inspect(reason)
    )
  end
end
