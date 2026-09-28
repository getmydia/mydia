defmodule MydiaWeb.Schema.Resolvers.DownloadResolver do
  @moduledoc """
  GraphQL resolvers for download operations.

  These resolvers enable P2P clients to use the same transcode/download
  functionality that's available via REST endpoints.
  """

  alias Mydia.Downloads.DownloadService

  @doc """
  Get available download quality options for a media item.

  Returns a list of available resolutions with estimated file sizes.
  """
  def download_options(_parent, %{content_type: content_type, id: id}, %{context: context}) do
    case DownloadService.get_options(context[:current_scope], content_type, id) do
      {:ok, options} -> {:ok, options}
      {:error, error} -> {:error, format_error(error)}
    end
  end

  @doc """
  Start or return existing transcode job for download.

  Returns job_id, status, and progress.
  """
  def prepare_download(_parent, args, %{context: context}) do
    content_type = args[:content_type]
    id = args[:id]
    resolution = args[:resolution] || "720p"

    case DownloadService.prepare(context[:current_scope], content_type, id, resolution) do
      {:ok, job_info} -> {:ok, job_info}
      {:error, error} -> {:error, format_error(error)}
    end
  end

  @doc """
  Get current status and progress of a transcode job.
  """
  def job_status(_parent, %{job_id: job_id}, _resolution) do
    case DownloadService.get_job_status(job_id) do
      {:ok, job_info} -> {:ok, job_info}
      {:error, :job_not_found} -> {:error, "Job not found"}
    end
  end

  @doc """
  Cancel a transcode job.
  """
  def cancel_job(_parent, %{job_id: job_id}, _resolution) do
    case DownloadService.cancel_job(job_id) do
      {:ok, :cancelled} -> {:ok, %{success: true}}
      {:error, :job_not_found} -> {:error, "Job not found"}
    end
  end

  ## Private Helpers

  defp format_error(:not_found), do: "Media not found"
  defp format_error(:no_media_file), do: "No media file available for download"

  defp format_error(:invalid_resolution),
    do: "Invalid resolution. Must be one of: original, 1080p, 720p, 480p"

  defp format_error(:source_file_not_found), do: "Source file not found"
  defp format_error(:job_not_found), do: "Job not found"
  defp format_error(error), do: "Error: #{inspect(error)}"
end
