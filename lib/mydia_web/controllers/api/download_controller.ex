defmodule MydiaWeb.Api.DownloadController do
  use MydiaWeb, :controller

  require Logger

  alias Mydia.Downloads
  alias Mydia.Downloads.DownloadService
  alias MydiaWeb.Api.RangeHelper

  @doc """
  GET /api/v1/download/:content_type/:id/options

  Returns available download quality options for a media file.

  ## Parameters
    - content_type: "movie" or "episode"
    - id: Media item ID (for movie) or Episode ID (for episode)

  ## Response
    {
      "options": [
        {"resolution": "1080p", "estimated_size": 5242880000},
        {"resolution": "720p", "estimated_size": 2621440000},
        {"resolution": "480p", "estimated_size": 1048576000}
      ]
    }
  """
  def options(conn, %{"content_type" => content_type, "id" => id}) do
    case DownloadService.get_options(conn.assigns.current_scope, content_type, id) do
      {:ok, options} ->
        conn
        |> put_status(:ok)
        |> json(%{options: options})

      {:error, error} ->
        handle_error(conn, error)
    end
  end

  @doc """
  POST /api/v1/download/:content_type/:id/prepare

  Starts or returns existing transcode job for download.

  ## Parameters
    - content_type: "movie" or "episode"
    - id: Media item ID (for movie) or Episode ID (for episode)

  ## Body
    {"resolution": "720p"}

  ## Response
    {
      "job_id": "uuid",
      "status": "pending|transcoding|ready",
      "progress": 0.0
    }
  """
  def prepare(conn, %{"content_type" => content_type, "id" => id} = params) do
    resolution = params["resolution"] || "720p"

    case DownloadService.prepare(conn.assigns.current_scope, content_type, id, resolution) do
      {:ok, job_info} ->
        conn
        |> put_status(:ok)
        |> json(%{
          job_id: job_info.job_id,
          status: job_info.status,
          progress: job_info.progress
        })

      {:error, error} ->
        handle_error(conn, error)
    end
  end

  @doc """
  GET /api/v1/download/job/:job_id/status

  Returns current status and progress of a transcode job.

  ## Response
    {
      "job_id": "uuid",
      "status": "pending|transcoding|ready|failed",
      "progress": 0.75,
      "error": null
    }
  """
  def job_status(conn, %{"job_id" => job_id}) do
    case DownloadService.get_job_status(job_id) do
      {:ok, job_info} ->
        conn
        |> put_status(:ok)
        |> json(%{
          job_id: job_info.job_id,
          status: job_info.status,
          progress: job_info.progress,
          error: job_info.error,
          file_size: job_info.file_size
        })

      {:error, :job_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Job not found"})
    end
  end

  @doc """
  DELETE /api/v1/download/job/:job_id

  Cancels a transcode job.

  ## Response
    {"status": "cancelled"}
  """
  def cancel_job(conn, %{"job_id" => job_id}) do
    case DownloadService.cancel_job(job_id) do
      {:ok, :cancelled} ->
        conn
        |> put_status(:ok)
        |> json(%{status: "cancelled"})

      {:error, :job_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Job not found"})
    end
  end

  @doc """
  GET /api/v1/download/job/:job_id/file

  Downloads the transcoded file with Range request support.

  Supports progressive download for files that are still being transcoded.
  """
  def download_file(conn, %{"job_id" => job_id}) do
    case DownloadService.get_job(job_id) do
      {:error, :job_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Job not found"})

      {:ok, %{status: "pending"} = _job} ->
        conn
        |> put_status(:accepted)
        |> json(%{error: "Transcode not started yet", status: "pending"})

      {:ok, %{status: "transcoding", output_path: output_path} = job}
      when not is_nil(output_path) ->
        # Transcoding in progress - allow progressive download
        serve_file_with_range(conn, job, output_path, transcoding: true)

      {:ok, %{status: "transcoding"} = _job} ->
        conn
        |> put_status(:accepted)
        |> json(%{error: "Transcode in progress, file not yet available", status: "transcoding"})

      {:ok, %{status: "ready", output_path: output_path} = job} when not is_nil(output_path) ->
        # Transcode complete - serve the file
        serve_file_with_range(conn, job, output_path, transcoding: false)

      {:ok, %{status: "failed", error: error} = _job} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Transcode failed: #{error || "Unknown error"}"})

      {:ok, _job} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "File not available"})
    end
  end

  ## Private Helpers

  defp handle_error(conn, :not_found) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "Media not found"})
  end

  defp handle_error(conn, :no_media_file) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "No media file available for download"})
  end

  defp handle_error(conn, :invalid_resolution) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Invalid resolution. Must be one of: original, 1080p, 720p, 480p"})
  end

  defp handle_error(conn, :source_file_not_found) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "Source file not found"})
  end

  defp handle_error(conn, reason) do
    Logger.error("Failed to prepare download: #{inspect(reason)}")

    conn
    |> put_status(:internal_server_error)
    |> json(%{error: "Failed to prepare download"})
  end

  # Serve file with Range request support
  defp serve_file_with_range(conn, job, file_path, opts) do
    transcoding = Keyword.get(opts, :transcoding, false)

    # Check if file exists
    case File.stat(file_path) do
      {:ok, %{size: file_size}} ->
        # Update last_accessed_at for LRU cache management
        Downloads.touch_last_accessed(job)

        # Get Range header
        range_header = get_req_header(conn, "range") |> List.first()

        case RangeHelper.parse_range_header(range_header, file_size) do
          {:ok, start, end_pos} ->
            # Partial content request
            {offset, length} = RangeHelper.calculate_range(start, end_pos)

            conn
            |> put_status(206)
            |> put_resp_content_type(RangeHelper.get_mime_type(file_path))
            |> put_resp_header("accept-ranges", "bytes")
            |> put_resp_header(
              "content-range",
              RangeHelper.format_content_range(start, end_pos, file_size)
            )
            |> put_resp_header("content-length", to_string(length))
            |> maybe_add_transcoding_header(transcoding)
            |> send_file(206, file_path, offset, length)

          :error ->
            # No range or invalid range - send entire file
            conn
            |> put_status(200)
            |> put_resp_content_type(RangeHelper.get_mime_type(file_path))
            |> put_resp_header("accept-ranges", "bytes")
            |> put_resp_header("content-length", to_string(file_size))
            |> maybe_add_transcoding_header(transcoding)
            |> send_file(200, file_path)
        end

      {:error, :enoent} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "File not found"})

      {:error, reason} ->
        Logger.error("Failed to stat file: #{inspect(reason)}")

        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to access file"})
    end
  end

  # Add custom header to indicate file is still being transcoded
  defp maybe_add_transcoding_header(conn, true) do
    put_resp_header(conn, "x-transcode-status", "in-progress")
  end

  defp maybe_add_transcoding_header(conn, false), do: conn
end
