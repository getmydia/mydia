defmodule Mydia.Library.Analysis do
  @moduledoc """
  Owns applying file analysis outcomes to media file rows and refreshing or repairing file metadata.
  """

  import Ecto.Query, warn: false
  import Mydia.DB
  require Logger
  alias Mydia.Repo
  alias Mydia.Library.{FileAnalyzer, MediaFile, MediaFiles}

  @doc """
  Applies a `FileAnalyzer.analyze/1` outcome to a `MediaFile` row.

  Two branches:

    * `{:ok, %FileAnalysisResult{}}` performs a guarded write
      (`UPDATE ... WHERE id = ? AND analyzed_at IS NULL`) that sets every
      tech-metadata column, populates `analyzed_at`, clears
      `last_analysis_error`, and bumps `updated_at`. Returns `:ok` when the
      write landed, `:already_analyzed` when another writer beat us.
    * `{:error, reason}` increments `analysis_attempts` and records
      `last_analysis_error` without touching tech metadata. Returns the
      original `{:error, reason}` so callers can decide how to surface it.

  Used by the recurring analysis worker, the lazy-on-play fallback in
  `Mydia.Streaming.Candidates`, and the operator-triggered
  `refresh_file_metadata/1`. The `WHERE analyzed_at IS NULL` guard makes
  concurrent writers safe: only the first success-write lands.
  """
  @spec apply_analysis(
          MediaFile.t(),
          {:ok, Mydia.Library.Structs.FileAnalysisResult.t()} | {:error, term()}
        ) :: :ok | :already_analyzed | {:error, term()}
  def apply_analysis(
        %MediaFile{} = media_file,
        {:ok, %Mydia.Library.Structs.FileAnalysisResult{} = result}
      ) do
    case apply_analysis_success(media_file, result) do
      :ok ->
        maybe_enqueue_upgrade_finalize(media_file)
        :ok

      other ->
        other
    end
  end

  def apply_analysis(%MediaFile{} = media_file, {:error, reason}) do
    apply_analysis_failure(media_file, reason)
  end

  # Enqueues Mydia.Jobs.UpgradeFinalize the moment a file that supersedes
  # another finishes analysis — the first point it can be scored against its
  # profile, and therefore the first point the upgrade/reject decision in
  # Mydia.Upgrades.finalize_upgrade/1 can be made. apply_analysis_success/2
  # only returns :ok on the actual nil -> analyzed transition (a
  # re-analysis returns :already_analyzed), so this fires exactly once per
  # import, never on a re-analysis of the same file.
  defp maybe_enqueue_upgrade_finalize(%MediaFile{supersedes_media_file_id: nil}), do: :ok

  defp maybe_enqueue_upgrade_finalize(%MediaFile{
         id: media_file_id,
         supersedes_media_file_id: supersedes_id
       })
       when is_binary(supersedes_id) do
    alias Mydia.Jobs.UpgradeFinalize

    changeset = UpgradeFinalize.new(%{"media_file_id" => media_file_id})

    case Mydia.Jobs.insert(changeset) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to enqueue UpgradeFinalize",
          media_file_id: media_file_id,
          reason: inspect(reason)
        )

        :ok
    end
  end

  defp apply_analysis_success(%MediaFile{} = media_file, result) do
    apply_analysis_success(media_file, result, 3)
  end

  defp apply_analysis_success(%MediaFile{} = media_file, result, retries_remaining) do
    alias Mydia.Library.Structs.FileMetadata
    alias Mydia.Streaming.Codec

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    current =
      Repo.one(
        from(mf in MediaFile,
          where: mf.id == ^media_file.id,
          select: %{
            metadata: mf.metadata,
            analyzed_at: mf.analyzed_at,
            updated_at: mf.updated_at
          }
        )
      )

    if is_nil(current) or current.analyzed_at do
      :already_analyzed
    else
      current_metadata = current.metadata || FileMetadata.empty()

      metadata =
        current_metadata
        |> maybe_put_struct_field(:duration, result.duration)
        |> maybe_put_struct_field(:container, result.container)
        |> maybe_put_struct_field(:width, result.width)
        |> maybe_put_struct_field(:height, result.height)
        |> maybe_put_struct_field(:streams, result.streams)
        # The `audio_codec` column below is normalized for streaming
        # compatibility, which collapses "DD+ 5.1" to "ac3" and "TrueHD Atmos"
        # to "truehd" — losing the channel layout and the Atmos/E-AC3
        # distinction that quality scoring needs. Keep the analyzer's own
        # string so `Mydia.Quality.Attrs` has something lossless to read.
        |> maybe_put_struct_field(:audio_codec_raw, result.audio_codec)

      write_analysis_success(
        media_file,
        result,
        metadata,
        current.updated_at,
        now,
        retries_remaining
      )
    end
  end

  defp write_analysis_success(
         media_file,
         result,
         metadata,
         expected_updated_at,
         now,
         retries_remaining
       ) do
    alias Mydia.Streaming.Codec

    set = [
      codec: Codec.normalize_video_codec(result.codec),
      audio_codec: Codec.normalize_audio_codec(result.audio_codec),
      resolution: result.resolution,
      bitrate: result.bitrate,
      hdr_format: result.hdr && result.hdr.base,
      dolby_vision_profile: result.hdr && result.hdr.dv_profile,
      dolby_vision_bl_compat_id: result.hdr && result.hdr.bl_compat_id,
      metadata: metadata,
      analyzed_at: now,
      analysis_attempts: 0,
      last_analysis_error: nil,
      updated_at: now
    ]

    # `size` is set only when ffprobe surfaced a value; otherwise we leave the
    # existing column alone so we do not overwrite a known size with nil.
    set = if result.size, do: Keyword.put(set, :size, result.size), else: set

    query =
      from(mf in MediaFile,
        where:
          mf.id == ^media_file.id and is_nil(mf.analyzed_at) and
            mf.updated_at == ^expected_updated_at
      )

    case Repo.update_all(query, set: set) do
      {1, _} ->
        :ok

      {0, _} when retries_remaining > 0 ->
        apply_analysis_success(media_file, result, retries_remaining - 1)

      {0, _} ->
        :already_analyzed
    end
  end

  defp apply_analysis_failure(%MediaFile{} = media_file, reason) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    reason_text = format_analysis_error(reason)

    # Guard against stale-failure writes: if another writer has already
    # populated analyzed_at, do not bump the attempts counter on what is now
    # a known-good row.
    query =
      from(mf in MediaFile,
        where: mf.id == ^media_file.id and is_nil(mf.analyzed_at)
      )

    Repo.update_all(query,
      inc: [analysis_attempts: 1],
      set: [last_analysis_error: reason_text, updated_at: now]
    )

    {:error, reason}
  end

  @doc """
  Clears analysis state on a `MediaFile` row so the next worker tick or
  manual retry treats it as un-analyzed again.

  Resets `analyzed_at`, `analysis_attempts`, and `last_analysis_error`.
  Intended as the building block for an operator-triggered retry surface.
  """
  @spec reset_analysis_state(MediaFile.t()) :: :ok | {:error, :not_found}
  def reset_analysis_state(%MediaFile{} = media_file) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    query = from(mf in MediaFile, where: mf.id == ^media_file.id)

    case Repo.update_all(query,
           set: [
             analyzed_at: nil,
             analysis_attempts: 0,
             last_analysis_error: nil,
             updated_at: now
           ]
         ) do
      {1, _} -> :ok
      {0, _} -> {:error, :not_found}
    end
  end

  defp maybe_put_struct_field(struct, _field, nil), do: struct
  defp maybe_put_struct_field(struct, field, value), do: Map.put(struct, field, value)

  defp record_repair_failure(%MediaFile{} = media_file, reason) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    reason_text = format_analysis_error(reason)

    query = from(mf in MediaFile, where: mf.id == ^media_file.id)

    Repo.update_all(query,
      inc: [analysis_attempts: 1],
      set: [last_analysis_error: reason_text, updated_at: now]
    )
  end

  defp apply_repair_analysis(%MediaFile{} = media_file, result) do
    apply_repair_analysis(media_file, result, 3)
  end

  defp apply_repair_analysis(%MediaFile{} = media_file, result, retries_remaining) do
    alias Mydia.Library.Structs.FileMetadata

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    current =
      Repo.one(
        from(mf in MediaFile,
          where: mf.id == ^media_file.id,
          select: %{
            metadata: mf.metadata,
            analyzed_at: mf.analyzed_at,
            updated_at: mf.updated_at
          }
        )
      )

    case current do
      nil ->
        {:error, :not_found}

      current ->
        metadata =
          current.metadata
          |> Kernel.||(FileMetadata.empty())
          |> maybe_put_struct_field(:duration, result.duration)
          |> maybe_put_struct_field(:container, result.container)
          |> maybe_put_struct_field(:width, result.width)
          |> maybe_put_struct_field(:height, result.height)
          |> maybe_put_struct_field(:streams, result.streams)

        set = build_analysis_success_set(result, metadata, now)

        # This guard must stay in lockstep with FileAnalysis.fetch_repair_rows/3
        # and repair_candidate?/1. If it is narrower than the selection, the
        # lane re-probes the same rows on every tick and writes nothing.
        query =
          from(mf in MediaFile,
            where:
              mf.id == ^media_file.id and mf.updated_at == ^current.updated_at and
                mf.analyzed_at == ^current.analyzed_at and
                (is_nil(json_extract(mf.metadata, "$.width")) or
                   is_nil(json_extract(mf.metadata, "$.height")) or
                   is_nil(json_extract(mf.metadata, "$.streams")))
          )

        case Repo.update_all(query, set: set) do
          {1, _} ->
            :ok

          {0, _} when retries_remaining > 0 ->
            apply_repair_analysis(media_file, result, retries_remaining - 1)

          {0, _} ->
            {:error, :not_found}
        end
    end
  end

  defp build_analysis_success_set(result, metadata, now) do
    alias Mydia.Streaming.Codec

    set = [
      codec: Codec.normalize_video_codec(result.codec),
      audio_codec: Codec.normalize_audio_codec(result.audio_codec),
      resolution: result.resolution,
      bitrate: result.bitrate,
      hdr_format: result.hdr && result.hdr.base,
      dolby_vision_profile: result.hdr && result.hdr.dv_profile,
      dolby_vision_bl_compat_id: result.hdr && result.hdr.bl_compat_id,
      metadata: metadata,
      analyzed_at: now,
      analysis_attempts: 0,
      last_analysis_error: nil,
      updated_at: now
    ]

    if result.size, do: Keyword.put(set, :size, result.size), else: set
  end

  @max_analysis_error_length 2048

  defp format_analysis_error(reason) when is_atom(reason), do: inspect(reason)
  defp format_analysis_error(reason) when is_binary(reason), do: truncate_analysis_error(reason)
  defp format_analysis_error(reason), do: reason |> inspect() |> truncate_analysis_error()

  defp truncate_analysis_error(reason_text) do
    String.slice(reason_text, 0, @max_analysis_error_length)
  end

  @doc """
  Refreshes file metadata for a specific media file by re-analyzing it.

  Uses both filename parsing and FFprobe analysis, preferring actual file metadata.

  The library_path association must be preloaded.

  Returns {:ok, updated_media_file} or {:error, reason}.
  """
  @spec refresh_file_metadata(MediaFile.t()) :: {:ok, MediaFile.t()} | {:error, term()}
  def refresh_file_metadata(%MediaFile{} = media_file) do
    case MediaFile.absolute_path(media_file) do
      nil ->
        Logger.error("Cannot refresh file metadata - path could not be resolved",
          file_id: media_file.id
        )

        {:error, :path_not_resolved}

      absolute_path ->
        if File.exists?(absolute_path) do
          # Operator-triggered retry: clear analysis_attempts first so the row
          # is no longer blocked by the worker's ceiling, then re-run ffprobe
          # and route the write through apply_analysis/2 to share the guarded
          # write with the worker and the lazy fallback. If the row was deleted
          # mid-flight we surface that cleanly rather than letting the later
          # get_media_file!/2 raise.
          with :ok <- reset_analysis_state(media_file) do
            result = FileAnalyzer.analyze(absolute_path)
            apply_analysis_outcome = apply_analysis(media_file, result)
            handle_refresh_outcome(media_file, absolute_path, apply_analysis_outcome, result)
          end
        else
          Logger.warning("File does not exist, cannot refresh metadata",
            file_id: media_file.id,
            path: absolute_path
          )

          {:error, :file_not_found}
        end
    end
  end

  defp handle_refresh_outcome(media_file, absolute_path, outcome, _result)
       when outcome in [:ok, :already_analyzed] do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(mf in MediaFile, where: mf.id == ^media_file.id)
    |> Repo.update_all(set: [verified_at: now])

    updated_file = MediaFiles.get_media_file!(media_file.id, preload: [:library_path])

    Logger.info("Refreshed file metadata",
      file_id: media_file.id,
      path: absolute_path,
      resolution: updated_file.resolution,
      codec: updated_file.codec,
      audio: updated_file.audio_codec
    )

    {:ok, updated_file}
  end

  defp handle_refresh_outcome(media_file, _absolute_path, {:error, reason}, _result) do
    Logger.warning("FFprobe analysis failed during refresh",
      file_id: media_file.id,
      reason: inspect(reason)
    )

    {:error, reason}
  end

  @doc """
  Refreshes file metadata for a media file by ID.

  Returns {:ok, updated_media_file} or {:error, reason}.
  """
  @spec refresh_file_metadata_by_id(binary()) :: {:ok, MediaFile.t()} | {:error, term()}
  def refresh_file_metadata_by_id(media_file_id) do
    media_file = MediaFiles.get_media_file!(media_file_id, preload: [:library_path])
    refresh_file_metadata(media_file)
  end

  @doc """
  Re-analyzes an already-analyzed file in place without clearing the existing
  analysis state first.

  Intended for self-healing passes that backfill newly tracked metadata fields
  or repair legacy analyzer mistakes while preserving the old row on failure.
  """
  @spec repair_file_metadata(MediaFile.t()) :: {:ok, MediaFile.t()} | {:error, term()}
  def repair_file_metadata(%MediaFile{} = media_file) do
    case MediaFile.absolute_path(media_file) do
      nil ->
        Logger.error("Cannot repair file metadata - path could not be resolved",
          file_id: media_file.id
        )

        {:error, :path_not_resolved}

      absolute_path ->
        if File.exists?(absolute_path) do
          case FileAnalyzer.analyze(absolute_path) do
            {:ok, result} ->
              case apply_repair_analysis(media_file, result) do
                :ok ->
                  updated_file =
                    MediaFiles.get_media_file!(media_file.id, preload: [:library_path])

                  Logger.info("Repaired file metadata",
                    file_id: media_file.id,
                    path: absolute_path,
                    resolution: updated_file.resolution,
                    codec: updated_file.codec,
                    audio: updated_file.audio_codec
                  )

                  {:ok, updated_file}

                {:error, :not_found} = error ->
                  error
              end

            {:error, reason} ->
              record_repair_failure(media_file, reason)

              Logger.warning("FFprobe analysis failed during repair",
                file_id: media_file.id,
                reason: inspect(reason)
              )

              {:error, reason}
          end
        else
          Logger.warning("File does not exist, cannot repair metadata",
            file_id: media_file.id,
            path: absolute_path
          )

          {:error, :file_not_found}
        end
    end
  end

  @doc false
  # Test seam for the repair write path, which is otherwise only reachable
  # through repair_file_metadata/1 and therefore through a real ffprobe run.
  def apply_repair_analysis_for_test(%MediaFile{} = media_file, result) do
    apply_repair_analysis(media_file, result)
  end

  @doc """
  Refreshes file metadata for all media files in the library.

  This can be a long-running operation. Returns the count of successfully refreshed files.
  """
  @spec refresh_all_file_metadata() :: {:ok, non_neg_integer()}
  def refresh_all_file_metadata do
    media_files = MediaFiles.list_media_files(preload: [:library_path])

    Logger.info("Starting bulk metadata refresh", total_files: length(media_files))

    results =
      Enum.map(media_files, fn file ->
        case refresh_file_metadata(file) do
          {:ok, _} -> :ok
          {:error, _} -> :error
        end
      end)

    success_count = Enum.count(results, &(&1 == :ok))
    error_count = Enum.count(results, &(&1 == :error))

    Logger.info("Completed bulk metadata refresh",
      success: success_count,
      errors: error_count
    )

    {:ok, success_count}
  end
end
