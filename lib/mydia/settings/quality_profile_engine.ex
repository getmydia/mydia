defmodule Mydia.Settings.QualityProfileEngine do
  @moduledoc """
  Batch application engine for QualityProfile evaluation and metadata preferences.

  This module provides functions to apply quality profiles to media files in batch,
  score files against quality standards, and apply metadata preferences during
  metadata refresh operations.

  ## Features

  - Evaluate individual media files against profile quality standards
  - Batch application to entire libraries with progress tracking
  - Concurrent processing using Task.async_stream with backpressure
  - Progress updates broadcast via PubSub for UI tracking
  - Profile-to-file association tracking with last_evaluated_at
  - Automatic re-evaluation when profiles are updated

  ## Examples

      # Evaluate a single file
      iex> evaluate_file(profile, media_file)
      {:ok, %{
        score: 85.5,
        breakdown: %{...},
        violations: [],
        recommendations: [...]
      }}

      # Apply profile to entire library
      iex> apply_profile_to_library(profile_id, library_path_id, fn progress ->
        IO.puts("Progress: \#{progress.processed}/\#{progress.total}")
      end)
      {:ok, %{
        processed: 1250,
        updated: 1200,
        skipped: 50,
        errors: []
      }}
  """

  require Logger
  import Ecto.Query
  alias Mydia.Quality.Sources
  alias Mydia.Repo
  alias Mydia.Settings.QualityProfile
  alias Mydia.Library.Hdr
  alias Mydia.Library.MediaFile
  alias Mydia.Library.Structs.FileMetadata
  alias Phoenix.PubSub

  @pubsub Mydia.PubSub

  @doc """
  Evaluates a media file against a quality profile's quality standards.

  Returns detailed evaluation results including quality score, breakdown by
  component, any violations, and recommendations for improvement.

  ## Parameters

    - `profile` - QualityProfile struct with quality_standards defined
    - `media_file` - MediaFile struct with media attributes

  ## Returns

    `{:ok, evaluation}` where evaluation is a map containing:
    - `:score` - Overall quality score (0.0 - 100.0)
    - `:breakdown` - Map with individual component scores
    - `:violations` - List of constraint violations
    - `:recommendations` - List of upgrade recommendations
    - `:evaluated_at` - Timestamp of evaluation

  ## Examples

      iex> evaluate_file(profile, media_file)
      {:ok, %{
        score: 85.5,
        breakdown: %{video_codec: 90.0, audio_codec: 85.0, ...},
        violations: [],
        recommendations: ["Consider upgrading to h265 for better compression"],
        evaluated_at: ~U[2025-01-24 19:00:00Z]
      }}
  """
  def evaluate_file(%QualityProfile{} = profile, %MediaFile{} = media_file) do
    # Extract media attributes from MediaFile
    media_attrs = extract_media_attributes(media_file)

    # Use QualityProfile.score_media_file/2 to calculate score
    scoring_result = QualityProfile.score_media_file(profile, media_attrs)

    # Generate recommendations based on scoring
    recommendations = generate_recommendations(profile, media_attrs, scoring_result)

    evaluation = %{
      score: scoring_result.score,
      breakdown: scoring_result.breakdown,
      violations: scoring_result.violations,
      recommendations: recommendations,
      evaluated_at: DateTime.utc_now()
    }

    {:ok, evaluation}
  end

  @doc """
  Applies a quality profile to all media files in a library path.

  Processes files concurrently using Task.async_stream with backpressure,
  broadcasts progress updates via PubSub, and returns summary statistics.

  ## Parameters

    - `profile_id` - ID of the quality profile to apply
    - `library_path_id` - ID of the library path to process
    - `opts` - Optional keyword list:
      - `:progress_callback` - Function to call with progress updates
      - `:concurrency` - Number of concurrent tasks (default: 10)
      - `:force_reevaluation` - Re-evaluate even if already evaluated (default: false)

  ## Returns

    `{:ok, summary}` where summary contains:
    - `:processed` - Total number of files processed
    - `:updated` - Number of files updated with new profile
    - `:skipped` - Number of files skipped (already evaluated)
    - `:errors` - List of {file_id, error} tuples

  ## Examples

      iex> apply_profile_to_library(profile_id, library_path_id, progress_callback: fn p ->
        IO.puts("Processed: \#{p.processed}/\#{p.total}")
      end)
      {:ok, %{processed: 1250, updated: 1200, skipped: 50, errors: []}}
  """
  def apply_profile_to_library(profile_id, library_path_id, opts \\ []) do
    with {:ok, profile} <- fetch_profile(profile_id),
         {:ok, files} <- fetch_library_files(library_path_id, opts) do
      process_batch(profile, files, opts)
    end
  end

  @doc """
  Applies a quality profile to specific media items.

  Similar to apply_profile_to_library/3 but operates on a specific set of
  media item IDs rather than an entire library path.

  ## Parameters

    - `profile_id` - ID of the quality profile to apply
    - `media_item_ids` - List of media item IDs to process
    - `opts` - Optional keyword list (same as apply_profile_to_library/3)

  ## Returns

    Same format as apply_profile_to_library/3
  """
  def apply_profile_to_items(profile_id, media_item_ids, opts \\ []) do
    with {:ok, profile} <- fetch_profile(profile_id),
         {:ok, files} <- fetch_item_files(media_item_ids, opts) do
      process_batch(profile, files, opts)
    end
  end

  @doc """
  Re-evaluates all files associated with a quality profile.

  Called automatically when a profile's quality_standards are updated to
  ensure all associated files are re-scored with the new criteria.

  ## Parameters

    - `profile_id` - ID of the profile that was updated

  ## Returns

    `{:ok, summary}` with processing statistics

  ## Examples

      iex> reevaluate_profile_files(profile_id)
      {:ok, %{processed: 500, updated: 500, skipped: 0, errors: []}}
  """
  def reevaluate_profile_files(profile_id) do
    with {:ok, profile} <- fetch_profile(profile_id),
         {:ok, files} <- fetch_profile_files(profile_id) do
      # Force re-evaluation even if already evaluated
      opts = [force_reevaluation: true]
      process_batch(profile, files, opts)
    end
  end

  ## Private Functions

  # Fetches a quality profile by ID
  defp fetch_profile(profile_id) do
    case Repo.get(QualityProfile, profile_id) do
      nil -> {:error, :profile_not_found}
      profile -> {:ok, profile}
    end
  end

  # Fetches all media files for a library path
  defp fetch_library_files(library_path_id, opts) do
    force_reevaluation = Keyword.get(opts, :force_reevaluation, false)

    query =
      MediaFile
      |> where([mf], mf.library_path_id == ^library_path_id)
      |> maybe_filter_already_evaluated(force_reevaluation)
      |> preload(:library_path)

    files = Repo.all(query)
    {:ok, files}
  end

  # Fetches media files for specific media items
  defp fetch_item_files(media_item_ids, opts) do
    force_reevaluation = Keyword.get(opts, :force_reevaluation, false)

    query =
      MediaFile
      |> where([mf], mf.media_item_id in ^media_item_ids or mf.episode_id in ^media_item_ids)
      |> maybe_filter_already_evaluated(force_reevaluation)
      |> preload(:library_path)

    files = Repo.all(query)
    {:ok, files}
  end

  # Fetches all files associated with a quality profile
  defp fetch_profile_files(profile_id) do
    query =
      MediaFile
      |> where([mf], mf.quality_profile_id == ^profile_id)
      |> preload(:library_path)

    files = Repo.all(query)
    {:ok, files}
  end

  # Optionally filters out files that have already been evaluated
  defp maybe_filter_already_evaluated(query, true = _force), do: query

  defp maybe_filter_already_evaluated(query, false) do
    # Only process files that haven't been evaluated yet
    # (i.e., quality_profile_id is nil or verified_at is nil)
    where(query, [mf], is_nil(mf.quality_profile_id) or is_nil(mf.verified_at))
  end

  # Processes a batch of files with concurrent evaluation
  defp process_batch(profile, files, opts) do
    concurrency = Keyword.get(opts, :concurrency, 10)
    progress_callback = Keyword.get(opts, :progress_callback)
    total = length(files)

    # Generate unique batch ID for PubSub topic
    batch_id = generate_batch_id()

    # Initialize processing state
    state = %{
      processed: 0,
      updated: 0,
      skipped: 0,
      errors: [],
      total: total,
      batch_id: batch_id
    }

    # Broadcast batch start
    broadcast_progress(batch_id, :started, state)

    # Process files concurrently
    result =
      files
      |> Task.async_stream(
        fn file ->
          process_single_file(profile, file)
        end,
        max_concurrency: concurrency,
        timeout: :infinity,
        on_timeout: :kill_task
      )
      |> Enum.reduce(state, fn result, acc ->
        acc = update_state(acc, result)

        # Broadcast progress update
        broadcast_progress(batch_id, :progress, acc)

        # Call progress callback if provided
        if progress_callback do
          progress_callback.(acc)
        end

        acc
      end)

    # Broadcast batch complete
    broadcast_progress(batch_id, :completed, result)

    summary = %{
      processed: result.processed,
      updated: result.updated,
      skipped: result.skipped,
      errors: result.errors
    }

    {:ok, summary}
  end

  # Processes a single file evaluation and profile assignment
  defp process_single_file(profile, file) do
    with {:ok, evaluation} <- evaluate_file(profile, file),
         {:ok, _updated_file} <- assign_profile_to_file(file, profile, evaluation) do
      {:ok, :updated}
    else
      {:error, :skip} ->
        {:ok, :skipped}

      {:error, reason} ->
        {:error, {file.id, reason}}
    end
  end

  # Assigns a quality profile to a media file with evaluation results
  defp assign_profile_to_file(file, profile, evaluation) do
    # Store evaluation metadata
    current_metadata = file.metadata || FileMetadata.empty()

    metadata = %{
      current_metadata
      | quality_evaluation: %{
          "score" => evaluation.score,
          "breakdown" => stringify_keys(evaluation.breakdown),
          "violations" => evaluation.violations,
          "recommendations" => evaluation.recommendations,
          "evaluated_at" => DateTime.to_iso8601(evaluation.evaluated_at)
        }
    }

    changeset =
      file
      |> Ecto.Changeset.change(%{
        quality_profile_id: profile.id,
        verified_at: DateTime.utc_now(),
        metadata: metadata
      })

    case Repo.update(changeset) do
      {:ok, updated_file} ->
        Logger.debug("Assigned quality profile to media file",
          file_id: file.id,
          profile_id: profile.id,
          score: evaluation.score
        )

        {:ok, updated_file}

      {:error, changeset} ->
        Logger.warning("Failed to assign quality profile to media file",
          file_id: file.id,
          profile_id: profile.id,
          errors: inspect(changeset.errors)
        )

        {:error, :update_failed}
    end
  end

  # Updates processing state based on task result
  defp update_state(state, {:ok, {:ok, :updated}}) do
    %{state | processed: state.processed + 1, updated: state.updated + 1}
  end

  defp update_state(state, {:ok, {:ok, :skipped}}) do
    %{state | processed: state.processed + 1, skipped: state.skipped + 1}
  end

  defp update_state(state, {:ok, {:error, error}}) do
    %{
      state
      | processed: state.processed + 1,
        errors: [error | state.errors]
    }
  end

  defp update_state(state, {:exit, reason}) do
    %{
      state
      | processed: state.processed + 1,
        errors: [{:task_exit, reason} | state.errors]
    }
  end

  # Broadcasts progress updates via PubSub
  defp broadcast_progress(batch_id, event_type, state) do
    topic = "quality_profile:batch:#{batch_id}"

    message = %{
      event: event_type,
      batch_id: batch_id,
      processed: state.processed,
      total: state.total,
      updated: state.updated,
      skipped: state.skipped,
      error_count: length(state.errors),
      progress_percent: calculate_progress_percent(state.processed, state.total),
      timestamp: DateTime.utc_now()
    }

    PubSub.broadcast(@pubsub, topic, {:quality_profile_progress, message})
  end

  # Calculates progress percentage
  defp calculate_progress_percent(0, _total), do: 0.0
  defp calculate_progress_percent(_processed, 0), do: 0.0

  defp calculate_progress_percent(processed, total) do
    Float.round(processed / total * 100, 1)
  end

  # Generates a unique batch ID
  defp generate_batch_id do
    "batch_#{:erlang.unique_integer([:positive, :monotonic])}_#{System.system_time(:millisecond)}"
  end

  # Extracts media attributes from MediaFile for scoring
  defp extract_media_attributes(media_file) do
    # Determine media type based on parent association
    media_type =
      cond do
        media_file.media_item_id -> :movie
        media_file.episode_id -> :episode
        true -> :unknown
      end

    # Convert bytes to MB for file size
    file_size_mb = if media_file.size, do: div(media_file.size, 1_048_576), else: nil

    # Build attributes map
    %{
      video_codec: media_file.codec,
      audio_codec: media_file.audio_codec,
      audio_channels: extract_audio_channels(media_file),
      resolution: media_file.resolution,
      source: extract_source(media_file),
      file_size_mb: file_size_mb,
      media_type: media_type,
      hdr_tokens:
        Hdr.profile_tokens(%Hdr{
          base: media_file.hdr_format,
          dv_profile: media_file.dolby_vision_profile,
          bl_compat_id: media_file.dolby_vision_bl_compat_id
        })
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  # Extracts audio channels from metadata
  defp extract_audio_channels(media_file) do
    case media_file.metadata do
      %{"audio_channels" => channels} when is_binary(channels) -> channels
      %{"audio" => %{"channels" => channels}} when is_binary(channels) -> channels
      _ -> nil
    end
  end

  # Extracts source type from metadata or filename
  defp extract_source(media_file) do
    case media_file.metadata do
      %{"source" => source} when is_binary(source) ->
        source

      _ ->
        # Try to infer from filename
        relative_path = media_file.relative_path || ""
        infer_source_from_filename(relative_path)
    end
  end

  @doc """
  Infers the source type from a media file's relative path.

  Public so the source vocabulary can be tested directly against real on-disk
  paths. Delegates to `Mydia.Quality.Sources` so the on-disk path and the
  indexer search path agree on what a release is.
  """
  @spec infer_source_from_filename(String.t()) :: String.t() | nil
  def infer_source_from_filename(filename) when is_binary(filename) do
    Sources.detect(filename)
  end

  def infer_source_from_filename(_), do: nil

  # Generates upgrade recommendations based on scoring results
  defp generate_recommendations(profile, media_attrs, scoring_result) do
    recommendations = []

    # Video codec recommendations
    recommendations =
      if scoring_result.breakdown.video_codec < 80.0 do
        preferred_codecs = get_in(profile.quality_standards, [:preferred_video_codecs]) || []

        if Enum.any?(preferred_codecs) do
          best_codec = List.first(preferred_codecs)
          ["Consider upgrading to #{best_codec} video codec" | recommendations]
        else
          recommendations
        end
      else
        recommendations
      end

    # Audio codec recommendations
    recommendations =
      if scoring_result.breakdown.audio_codec < 80.0 do
        preferred_codecs = get_in(profile.quality_standards, [:preferred_audio_codecs]) || []

        if Enum.any?(preferred_codecs) do
          best_codec = List.first(preferred_codecs)
          ["Consider upgrading to #{best_codec} audio codec" | recommendations]
        else
          recommendations
        end
      else
        recommendations
      end

    # Resolution recommendations
    recommendations =
      if scoring_result.breakdown.resolution < 80.0 do
        preferred_resolutions = QualityProfile.preferred_resolutions(profile)

        if Enum.any?(preferred_resolutions) do
          best_resolution = List.first(preferred_resolutions)
          ["Consider upgrading to #{best_resolution} resolution" | recommendations]
        else
          recommendations
        end
      else
        recommendations
      end

    # HDR recommendations
    recommendations =
      if scoring_result.breakdown.hdr < 80.0 and
           get_in(profile.quality_standards, [:require_hdr]) == false do
        hdr_formats = get_in(profile.quality_standards, [:hdr_formats]) || []

        if Enum.any?(hdr_formats) and Map.get(media_attrs, :hdr_tokens, []) == [] do
          best_hdr = List.first(hdr_formats)
          ["Consider upgrading to #{best_hdr} HDR format" | recommendations]
        else
          recommendations
        end
      else
        recommendations
      end

    Enum.reverse(recommendations)
  end

  # Converts atom keys to strings for JSON storage
  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end
end
