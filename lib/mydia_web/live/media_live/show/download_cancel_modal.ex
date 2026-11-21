defmodule MydiaWeb.MediaLive.Show.DownloadCancelModal do
  @moduledoc """
  The media page's confirm for cancelling an in-flight download. Submitting
  sends `cancel_download` with `delete_files`, handled by
  `MydiaWeb.MediaLive.Show.DownloadEvents.cancel_download/2`.
  """
  use Phoenix.Component
  use Gettext, backend: MydiaWeb.Gettext

  import MydiaWeb.CoreComponents
  import MydiaWeb.MediaLive.Show.Formatters, only: [format_download_quality: 1]
  import MydiaWeb.Formatters, only: [format_progress: 1]

  attr :download_to_cancel, :map, required: true

  def download_cancel_confirm_modal(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box">
        <h3 class="font-bold text-lg mb-4">{gettext("Cancel Download?")}</h3>
        <p class="py-4">{gettext("Are you sure you want to cancel this download?")}</p>
        <div class="bg-base-200 p-3 rounded-box mb-4">
          <p class="text-sm font-medium">{@download_to_cancel.title}</p>
          <%= if quality = @download_to_cancel.metadata["quality"] do %>
            <p class="text-sm text-base-content/70 mt-1">
              {gettext("Quality:")}
              <span class="badge badge-sm">{format_download_quality(quality)}</span>
            </p>
          <% end %>
          <%= if @download_to_cancel.progress do %>
            <p class="text-sm text-base-content/70 mt-1">
              {gettext("Progress:")} {format_progress(@download_to_cancel.progress)}%
            </p>
          <% end %>
        </div>
        <MydiaWeb.SeedingComponents.removal_warning download={@download_to_cancel} />
        <p class="text-warning text-sm mb-4">
          <.icon name="hero-exclamation-triangle" class="w-4 h-4 inline" />
          {gettext("The download will be stopped and marked as cancelled.")}
        </p>
        <%!-- Partial files left behind made a later grab of the same release
             fail (issue #1436), so deleting them is the default. --%>
        <form id="download-cancel-form" phx-submit="cancel_download">
          <label class="label cursor-pointer justify-start gap-3">
            <%!-- Unchecked boxes submit nothing; the hidden input says "false". --%>
            <input type="hidden" name="delete_files" value="false" />
            <input
              id="download-cancel-delete-files"
              type="checkbox"
              name="delete_files"
              value="true"
              checked
              class="checkbox checkbox-error"
            />
            <span class="label-text whitespace-normal">
              {gettext("Also delete the partly downloaded files from the download folder")}
            </span>
          </label>
        </form>
        <div class="modal-action">
          <button type="button" phx-click="hide_download_cancel_confirm" class="btn btn-ghost">
            {gettext("Keep Downloading")}
          </button>
          <button type="submit" form="download-cancel-form" class="btn btn-warning">
            {gettext("Cancel Download")}
          </button>
        </div>
      </div>
      <div class="modal-backdrop" phx-click="hide_download_cancel_confirm"></div>
    </div>
    """
  end
end
