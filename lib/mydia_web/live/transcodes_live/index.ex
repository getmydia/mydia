defmodule MydiaWeb.TranscodesLive.Index do
  use MydiaWeb, :live_view
  alias Mydia.Downloads
  alias Phoenix.PubSub
  alias MydiaWeb.Live.Authorization

  require Logger

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
        {:noreply, put_flash(socket, :info, "Job cancelled")}
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

  def handle_info(msg, socket) do
    Logger.warning("Unhandled message in TranscodesLive.Index: #{inspect(msg)}")
    {:noreply, socket}
  end

  defp load_jobs(socket) do
    jobs = Downloads.list_transcode_jobs(preload: [:media_file])

    # Enrich with media info if possible (media_file -> library_path -> media_item)
    # Ideally we'd preload deeper, but for now let's just show basic info

    stream(socket, :jobs, jobs, reset: true)
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
end
