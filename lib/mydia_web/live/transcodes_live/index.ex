defmodule MydiaWeb.TranscodesLive.Index do
  use MydiaWeb, :live_view

  on_mount {MydiaWeb.PlayerHooks, :require_player}

  alias Mydia.Downloads
  alias Phoenix.PubSub
  alias MydiaWeb.Live.Authorization

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      PubSub.subscribe(Mydia.PubSub, "transcodes")
    end

    {:ok,
     socket
     |> assign(:page_title, "Transcodes")
     |> load_jobs()}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("cancel", %{"id" => id}, socket) do
    with :ok <- Authorization.authorize_manage_downloads(socket) do
      job = Mydia.Repo.get(Downloads.TranscodeJob, id)

      if job do
        Downloads.cancel_transcode_job(job)
        {:noreply, socket |> put_flash(:info, "Job cancelled") |> load_jobs()}
      else
        {:noreply, put_flash(socket, :error, "Job not found")}
      end
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:job_updated, _id}, socket) do
    {:noreply, load_jobs(socket)}
  end

  defp load_jobs(socket) do
    jobs = Downloads.list_transcode_jobs(preload: [:media_file])

    socket
    |> assign(:jobs_empty?, Enum.empty?(jobs))
    |> stream(:jobs, jobs, reset: true)
  end

  defp status_badge_class(status) do
    case status do
      "ready" -> "badge-success"
      "transcoding" -> "badge-primary"
      "pending" -> "badge-info"
      "failed" -> "badge-error"
      _ -> "badge-ghost"
    end
  end

  defp format_progress(nil), do: "0%"
  defp format_progress(progress), do: "#{Float.round(progress * 100, 1)}%"

  defp format_started_at(nil), do: "Pending"
  defp format_started_at(%DateTime{} = dt), do: Timex.from_now(dt)
  defp format_started_at(_), do: "N/A"

  defp media_name(job) do
    case job.media_file do
      %{relative_path: path} when is_binary(path) and path != "" -> Path.basename(path)
      %{path: path} when is_binary(path) and path != "" -> Path.basename(path)
      _ -> job.media_file_id
    end
  end
end
