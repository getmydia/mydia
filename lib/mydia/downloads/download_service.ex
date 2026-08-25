defmodule Mydia.Downloads.DownloadService do
  @moduledoc """
  Unified service for download/transcode operations.

  Used by both REST API (DownloadController) and GraphQL (DownloadResolver)
  to provide consistent download functionality.

  ## Error Tuples

  All functions return consistent error tuples:
  - `{:error, :not_found}` - Media item not found
  - `{:error, :no_media_file}` - No media file available for download
  - `{:error, :invalid_resolution}` - Invalid resolution parameter
  - `{:error, :source_file_not_found}` - Source file not found on disk
  - `{:error, :job_not_found}` - Transcode job not found
  """

  require Logger

  alias Mydia.Accounts.Scope
  alias Mydia.Library
  alias Mydia.Media
  alias Mydia.Downloads
  alias Mydia.Downloads.JobManager
  alias Mydia.Downloads.TranscodeJob
  alias Mydia.Repo

  @valid_resolutions ["original", "1080p", "720p", "480p"]

  @doc """
  Gets available download quality options for a media item.

  ## Parameters
    - content_type: "movie" or "episode"
    - id: Media item ID (for movie) or Episode ID (for episode)

  ## Returns
    - `{:ok, options}` - List of available quality options
    - `{:error, :not_found}` - Media not found
    - `{:error, :no_media_file}` - No media file available

  ## Example

      iex> get_options("movie", media_item_id)
      {:ok, [
        %{resolution: "original", label: "Original", estimated_size: 5242880000},
        %{resolution: "1080p", label: "1080p (Full HD)", estimated_size: 5242880000},
        %{resolution: "720p", label: "720p (HD)", estimated_size: 2621440000}
      ]}
  """
  def get_options(content_type, id) do
    with {:ok, media_file} <- get_media_file(content_type, id) do
      options = calculate_quality_options(media_file)
      {:ok, options}
    end
  end

  @doc """
  Prepares a download by creating/returning a transcode job.

  ## Parameters
    - content_type: "movie" or "episode"
    - id: Media item ID (for movie) or Episode ID (for episode)
    - resolution: Target resolution ("original", "1080p", "720p", "480p")

  ## Returns
    - `{:ok, job_info}` - Map with job_id, status, progress, file_size
    - `{:error, :not_found}` - Media not found
    - `{:error, :no_media_file}` - No media file available
    - `{:error, :invalid_resolution}` - Invalid resolution
    - `{:error, :source_file_not_found}` - Source file not found

  ## Example

      iex> prepare("movie", media_item_id, "720p")
      {:ok, %{job_id: "uuid", status: "pending", progress: 0.0, file_size: nil}}
  """
  def prepare(content_type, id, resolution \\ "720p") do
    with {:ok, media_file} <- get_media_file(content_type, id),
         {:ok, validated_resolution} <- validate_resolution(resolution),
         {:ok, job} <- Downloads.get_or_create_job(media_file.id, validated_resolution),
         :ok <- maybe_start_transcode(job, media_file) do
      # Refetch job to get updated status (e.g. if original quality completed immediately)
      job = Repo.get(TranscodeJob, job.id)

      {:ok,
       %{
         job_id: job.id,
         status: job.status,
         progress: job.progress || 0.0,
         file_size: job.file_size
       }}
    end
  end

  @doc """
  Gets the current status of a transcode job.

  ## Parameters
    - job_id: The transcode job ID

  ## Returns
    - `{:ok, job_info}` - Map with job_id, status, progress, error, file_size
    - `{:error, :job_not_found}` - Job not found

  ## Example

      iex> get_job_status(job_id)
      {:ok, %{job_id: "uuid", status: "transcoding", progress: 0.5, error: nil, file_size: nil}}
  """
  def get_job_status(job_id) do
    case Repo.get(TranscodeJob, job_id) do
      nil ->
        {:error, :job_not_found}

      job ->
        {:ok,
         %{
           job_id: job.id,
           status: job.status,
           progress: job.progress || 0.0,
           error: job.error,
           file_size: job.file_size
         }}
    end
  end

  @doc """
  Cancels a transcode job.

  ## Parameters
    - job_id: The transcode job ID

  ## Returns
    - `{:ok, :cancelled}` - Job successfully cancelled
    - `{:error, :job_not_found}` - Job not found

  ## Example

      iex> cancel_job(job_id)
      {:ok, :cancelled}
  """
  def cancel_job(job_id) do
    case Repo.get(TranscodeJob, job_id) do
      nil ->
        {:error, :job_not_found}

      job ->
        # Cancel the job in JobManager if it's running
        case Repo.preload(job, :media_file) do
          %{media_file: media_file} when not is_nil(media_file) ->
            resolution_atom = resolution_to_atom(job.resolution)
            JobManager.cancel_job(media_file.id, resolution_atom)
            Downloads.cancel_transcode_job(job)
            {:ok, :cancelled}

          _ ->
            # Job has no media_file, just delete it
            Downloads.cancel_transcode_job(job)
            {:ok, :cancelled}
        end
    end
  end

  @doc """
  Gets a transcode job by ID.

  ## Parameters
    - job_id: The transcode job ID

  ## Returns
    - `{:ok, job}` - The transcode job
    - `{:error, :job_not_found}` - Job not found
  """
  def get_job(job_id) do
    case Repo.get(TranscodeJob, job_id) do
      nil -> {:error, :job_not_found}
      job -> {:ok, job}
    end
  end

  @doc """
  Prepares a download by media file ID directly.

  Used by the admin pre-transcode UI where the file is already known.

  ## Parameters
    - media_file_id: The media file ID
    - resolution: Target resolution ("original", "1080p", "720p", "480p")

  ## Returns
    - `{:ok, job_info}` - Map with job_id, status, progress, file_size
    - `{:error, reason}` - Error tuple
  """
  def prepare_by_file(media_file_id, resolution) do
    case Repo.get(Mydia.Library.MediaFile, media_file_id) do
      nil ->
        {:error, :no_media_file}

      media_file ->
        media_file = Repo.preload(media_file, :library_path)

        with {:ok, validated_resolution} <- validate_resolution(resolution),
             {:ok, job} <- Downloads.get_or_create_job(media_file.id, validated_resolution),
             :ok <- maybe_start_transcode(job, media_file) do
          job = Repo.get(TranscodeJob, job.id)

          {:ok,
           %{
             job_id: job.id,
             status: job.status,
             progress: job.progress || 0.0,
             file_size: job.file_size
           }}
        end
    end
  end

  ## Private Helpers

  @doc false
  def get_media_file("movie", media_item_id) do
    case Media.get_media_item!(Scope.system(), media_item_id) do
      %{type: "movie"} = media_item ->
        case Library.get_media_files_for_item(media_item.id, preload: [:library_path]) do
          [media_file | _] -> {:ok, media_file}
          [] -> {:error, :no_media_file}
        end

      _ ->
        {:error, :not_found}
    end
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end

  def get_media_file("episode", episode_id) do
    case Media.get_episode!(Scope.system(), episode_id) do
      episode ->
        case Library.get_media_files_for_episode(episode.id, preload: [:library_path]) do
          [media_file | _] -> {:ok, media_file}
          [] -> {:error, :no_media_file}
        end
    end
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end

  def get_media_file(_content_type, _id), do: {:error, :not_found}

  @doc false
  def calculate_quality_options(media_file) do
    source_size = media_file.size || 0
    source_resolution = parse_resolution_height(media_file.resolution)

    # Look up existing transcode jobs for this file
    transcode_jobs = Downloads.list_transcode_jobs_for_media_file(media_file.id)
    jobs_by_resolution = Map.new(transcode_jobs, fn job -> {job.resolution, job} end)

    # Always include "original" as the first option (no transcoding)
    original_option =
      %{resolution: "original", label: "Original", estimated_size: source_size}
      |> enrich_with_transcode_status(Map.get(jobs_by_resolution, "original"))

    available_resolutions =
      [
        {"1080p", 1080, "1080p (Full HD)"},
        {"720p", 720, "720p (HD)"},
        {"480p", 480, "480p (SD)"}
      ]
      |> Enum.filter(fn {_resolution, height, _label} -> height <= source_resolution end)

    transcoded_options =
      Enum.map(available_resolutions, fn {resolution, height, label} ->
        estimated_size = estimate_file_size(source_size, source_resolution, height)

        %{resolution: resolution, label: label, estimated_size: estimated_size}
        |> enrich_with_transcode_status(Map.get(jobs_by_resolution, resolution))
      end)

    # Original first, then transcoded options
    [original_option | transcoded_options]
  end

  defp enrich_with_transcode_status(option, nil) do
    Map.merge(option, %{transcode_status: nil, transcode_progress: nil, actual_size: nil})
  end

  defp enrich_with_transcode_status(option, job) do
    Map.merge(option, %{
      transcode_status: job.status,
      transcode_progress: job.progress,
      actual_size: job.file_size
    })
  end

  @doc false
  def parse_resolution_height(nil), do: 1080
  def parse_resolution_height("4K"), do: 2160
  def parse_resolution_height("2160p"), do: 2160
  def parse_resolution_height("1080p"), do: 1080
  def parse_resolution_height("720p"), do: 720
  def parse_resolution_height("480p"), do: 480

  def parse_resolution_height(resolution) when is_binary(resolution) do
    # Try to extract number from string like "1920x1080"
    case Regex.run(~r/(\d+)x(\d+)/, resolution) do
      [_, _width, height] -> String.to_integer(height)
      _ -> 1080
    end
  end

  def parse_resolution_height(_), do: 1080

  @doc false
  def estimate_file_size(source_size, source_height, target_height)
      when source_height > 0 and target_height > 0 do
    # Rough estimate: file size scales quadratically with resolution
    # (due to both width and height scaling)
    ratio = target_height / source_height
    round(source_size * ratio * ratio)
  end

  def estimate_file_size(source_size, _source_height, _target_height), do: source_size

  @doc false
  def validate_resolution(resolution) when resolution in @valid_resolutions do
    {:ok, resolution}
  end

  def validate_resolution(_), do: {:error, :invalid_resolution}

  @doc false
  def resolution_to_atom("original"), do: :original
  def resolution_to_atom("1080p"), do: :p1080
  def resolution_to_atom("720p"), do: :p720
  def resolution_to_atom("480p"), do: :p480
  def resolution_to_atom(_), do: :p720

  # Handle "original" resolution - no transcoding, use source file directly
  defp maybe_start_transcode(%{status: "pending", resolution: "original"} = job, media_file) do
    media_file = Repo.preload(media_file, :library_path)

    case Mydia.Library.MediaFile.absolute_path(media_file) do
      nil ->
        {:error, :source_file_not_found}

      source_path ->
        file_size = media_file.size || 0
        Downloads.complete_job(job, source_path, file_size)
        :ok
    end
  end

  # Start transcode if job is pending (for non-original resolutions)
  defp maybe_start_transcode(%{status: "pending"} = job, media_file) do
    media_file = Repo.preload(media_file, :library_path)

    case Mydia.Library.MediaFile.absolute_path(media_file) do
      nil ->
        {:error, :source_file_not_found}

      input_path ->
        output_dir = Application.get_env(:mydia, :transcode_cache_dir, "/tmp/mydia/transcodes")
        File.mkdir_p!(output_dir)
        output_filename = "#{job.id}.mp4"
        output_path = Path.join(output_dir, output_filename)

        resolution_atom = resolution_to_atom(job.resolution)

        on_progress = fn progress ->
          Downloads.update_job_progress(job, progress)
        end

        on_complete = fn ->
          file_size =
            case File.stat(output_path) do
              {:ok, %{size: size}} -> size
              _ -> 0
            end

          Downloads.complete_job(job, output_path, file_size)
        end

        on_error = fn error ->
          Downloads.fail_job(job, inspect(error))
        end

        case JobManager.start_or_queue_job(
               media_file_id: media_file.id,
               resolution: resolution_atom,
               input_path: input_path,
               output_path: output_path,
               on_progress: on_progress,
               on_complete: on_complete,
               on_error: on_error
             ) do
          {:ok, _} -> :ok
          {:error, :already_exists} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # Job already started or completed
  defp maybe_start_transcode(_job, _media_file), do: :ok
end
