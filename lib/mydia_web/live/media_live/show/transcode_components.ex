defmodule MydiaWeb.MediaLive.Show.TranscodeComponents do
  @moduledoc """
  Pre-transcode job badges shown on media file rows.
  """
  use MydiaWeb, :html

  attr :file, :map, required: true
  attr :transcode_jobs, :list, default: []

  def transcode_controls(assigns) do
    ~H"""
    <%= if @transcode_jobs != [] do %>
      <div class="flex flex-wrap items-center gap-2">
        <.transcode_badge
          :for={job <- @transcode_jobs}
          job={job}
          file={@file}
        />
      </div>
    <% end %>
    """
  end

  attr :job, :map, required: true
  attr :file, :map, required: true

  def transcode_badge(assigns) do
    ~H"""
    <div class={[
      "badge badge-sm gap-1",
      transcode_badge_class(@job.status)
    ]}>
      <%= case @job.status do %>
        <% "ready" -> %>
          <.icon name="hero-check-circle-mini" class="w-3 h-3" />
          {@job.resolution}
        <% "transcoding" -> %>
          <span class="loading loading-spinner loading-xs"></span>
          {@job.resolution} {format_transcode_progress(@job.progress)}
        <% "pending" -> %>
          <.icon name="hero-clock" class="w-3 h-3" />
          {gettext("%{resolution} queued", resolution: @job.resolution)}
        <% "failed" -> %>
          <.icon name="hero-exclamation-triangle-mini" class="w-3 h-3" />
          {gettext("%{resolution} failed", resolution: @job.resolution)}
        <% _other -> %>
          {@job.resolution}
      <% end %>
      <%= if @job.status in ["pending", "transcoding"] do %>
        <button
          type="button"
          phx-click="cancel_transcode"
          phx-value-job-id={@job.id}
          class="ml-1 hover:text-error"
          title={gettext("Cancel transcode")}
        >
          <.icon name="hero-x-mark-mini" class="w-3 h-3" />
        </button>
      <% end %>
    </div>
    """
  end

  defp transcode_badge_class("ready"), do: "badge-success"
  defp transcode_badge_class("transcoding"), do: "badge-warning"
  defp transcode_badge_class("pending"), do: "badge-info"
  defp transcode_badge_class("failed"), do: "badge-error"
  defp transcode_badge_class(_), do: "badge-ghost"

  defp format_transcode_progress(nil), do: ""

  defp format_transcode_progress(progress) when is_float(progress) do
    "#{round(progress * 100)}%"
  end

  defp format_transcode_progress(_), do: ""

  @doc "Resolutions at or below the file's own that have no transcode job yet."
  def available_transcode_resolutions(file, jobs_by_resolution) do
    source_height = Mydia.Downloads.DownloadService.parse_resolution_height(file.resolution)

    [{"1080p", 1080}, {"720p", 720}, {"480p", 480}]
    |> Enum.filter(fn {_res, height} -> height <= source_height end)
    |> Enum.reject(fn {res, _height} -> Map.has_key?(jobs_by_resolution, res) end)
    |> Enum.map(fn {res, _height} -> res end)
  end
end
