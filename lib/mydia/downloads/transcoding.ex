defmodule Mydia.Downloads.Transcoding do
  @moduledoc false

  import Ecto.Query, warn: false
  import Mydia.QueryHelpers

  alias Mydia.Repo
  alias Mydia.Downloads.TranscodeJob
  alias Mydia.Library.MediaFile
  alias Phoenix.PubSub
  require Logger

  ## Public Functions

  def get_or_create_job(media_file_id, resolution) do
    # Explicitly filter for download type jobs
    case Repo.get_by(TranscodeJob,
           media_file_id: media_file_id,
           resolution: resolution,
           type: "download"
         ) do
      nil ->
        attrs = %{
          media_file_id: media_file_id,
          resolution: resolution,
          type: "download",
          status: "pending",
          progress: 0.0
        }

        %TranscodeJob{}
        |> TranscodeJob.changeset(attrs)
        |> Repo.insert()
        |> case do
          {:ok, job} ->
            {:ok, job}

          {:error, %Ecto.Changeset{} = changeset} ->
            if unique_download_job_conflict?(changeset) do
              {:ok,
               Repo.get_by!(TranscodeJob,
                 media_file_id: media_file_id,
                 resolution: resolution,
                 type: "download"
               )}
            else
              {:error, changeset}
            end

          error ->
            error
        end

      job ->
        {:ok, job}
    end
  end

  defp unique_download_job_conflict?(%Ecto.Changeset{} = changeset) do
    Enum.any?(changeset.errors, fn
      {_field, {_message, opts}} ->
        opts[:constraint] == :unique and
          to_string(opts[:constraint_name]) == "transcode_jobs_media_file_id_resolution_index"

      _ ->
        false
    end)
  end

  def get_cached_transcode(media_file_id, resolution) do
    TranscodeJob
    |> where([j], j.media_file_id == ^media_file_id)
    |> where([j], j.resolution == ^resolution)
    |> where([j], j.type == "download")
    |> where([j], j.status == "ready")
    |> Repo.one()
  end

  def update_job_progress(%TranscodeJob{} = job, progress) do
    attrs = %{
      progress: progress,
      status: "transcoding"
    }

    attrs =
      if is_nil(job.started_at) do
        Map.put(attrs, :started_at, DateTime.utc_now())
      else
        attrs
      end

    case job
         |> TranscodeJob.changeset(attrs)
         |> Repo.update() do
      {:ok, updated_job} ->
        broadcast_job_update(updated_job.id)
        {:ok, updated_job}

      error ->
        error
    end
  end

  def complete_job(%TranscodeJob{} = job, output_path, file_size) do
    case job
         |> TranscodeJob.changeset(%{
           status: "ready",
           progress: 1.0,
           output_path: output_path,
           file_size: file_size,
           completed_at: DateTime.utc_now(),
           last_accessed_at: DateTime.utc_now()
         })
         |> Repo.update() do
      {:ok, updated_job} ->
        broadcast_job_update(updated_job.id)
        {:ok, updated_job}

      error ->
        error
    end
  end

  def fail_job(%TranscodeJob{} = job, error_message) do
    case job
         |> TranscodeJob.changeset(%{
           status: "failed",
           error: error_message
         })
         |> Repo.update() do
      {:ok, updated_job} ->
        broadcast_job_update(updated_job.id)
        {:ok, updated_job}

      error ->
        error
    end
  end

  def touch_last_accessed(%TranscodeJob{} = job) do
    job
    |> TranscodeJob.changeset(%{last_accessed_at: DateTime.utc_now()})
    |> Repo.update()
  end

  def broadcast_job_update(job_id) do
    PubSub.broadcast(Mydia.PubSub, "transcodes", {:job_updated, job_id})
  end

  def list_transcode_jobs_for_media_file(media_file_id) do
    TranscodeJob
    |> where([j], j.media_file_id == ^media_file_id)
    |> where([j], j.type == "download")
    |> order_by([j], desc: j.updated_at)
    |> Repo.all()
  end

  def list_transcode_jobs(opts \\ []) do
    TranscodeJob
    |> maybe_filter_status(opts[:status])
    |> maybe_preload(opts[:preload])
    |> order_by([j], desc: j.updated_at)
    |> maybe_limit(opts[:limit])
    |> Repo.all()
  end

  def cancel_transcode_job(%TranscodeJob{} = job) do
    alias Mydia.Downloads.JobManager
    alias Mydia.Streaming.HlsSessionSupervisor

    case job.type do
      "download" ->
        # Convert schema string resolution to atom for JobManager
        resolution_atom =
          case job.resolution do
            "original" -> :original
            "1080p" -> :p1080
            "720p" -> :p720
            "480p" -> :p480
            _ -> :p720
          end

        # Cancel in JobManager
        JobManager.cancel_job(job.media_file_id, resolution_atom)

      "stream" ->
        # Stop HLS session if running
        if job.user_id do
          HlsSessionSupervisor.stop_session(job.media_file_id, job.user_id)
        end

      "direct" ->
        # Stop Direct Play session if running
        if job.user_id do
          HlsSessionSupervisor.stop_direct_session(job.media_file_id, job.user_id)
        end

      _ ->
        :ok
    end

    # Delete from DB
    Repo.delete(job)

    # Clean up output file if it exists (only for downloads)
    maybe_remove_output_file(job)

    broadcast_job_update(job.id)
    {:ok, job}
  end

  def delete_all_completed_jobs do
    jobs =
      TranscodeJob
      |> where([j], j.status in ["ready", "failed"])
      |> Repo.all()

    Enum.each(jobs, &cancel_transcode_job/1)
  end

  def delete_all_streaming_jobs do
    Repo.delete_all(from j in TranscodeJob, where: j.type in ["stream", "direct"])
  end

  ## Private Functions

  # An "original" download transcodes nothing, so complete_job/3 records the
  # library file itself as the output path. Unlinking that would delete the
  # user's media, so only artifacts we produced are removed.
  defp maybe_remove_output_file(%TranscodeJob{output_path: nil}), do: :ok

  defp maybe_remove_output_file(%TranscodeJob{output_path: output_path} = job) do
    cond do
      output_path in source_file_paths(job) ->
        Logger.debug("Keeping #{output_path} on cancel: it is the source file, not a transcode")

      File.exists?(output_path) ->
        File.rm(output_path)

      true ->
        :ok
    end

    :ok
  end

  defp source_file_paths(%TranscodeJob{media_file_id: nil}), do: []

  defp source_file_paths(%TranscodeJob{media_file_id: media_file_id}) do
    case Repo.get(MediaFile, media_file_id) do
      nil ->
        []

      media_file ->
        media_file = Repo.preload(media_file, :library_path)

        [MediaFile.absolute_path(media_file), media_file.path]
        |> Enum.reject(&is_nil/1)
    end
  end

  defp maybe_filter_status(query, nil), do: query

  defp maybe_filter_status(query, statuses) when is_list(statuses),
    do: where(query, [j], j.status in ^statuses)

  defp maybe_limit(query, nil), do: query
  defp maybe_limit(query, limit), do: limit(query, ^limit)
end
