defmodule MydiaWeb.MediaLive.Show.DownloadAudioEvents do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Mydia.Media
  alias Mydia.Upgrades
  alias MydiaWeb.Live.Authorization

  def show_download_audio_modal(_params, socket) do
    {:noreply, assign(socket, :show_download_audio_modal, true)}
  end

  def hide_download_audio_modal(_params, socket) do
    {:noreply, assign(socket, :show_download_audio_modal, false)}
  end

  # The Server default row sends "default" rather than an empty value, so the
  # reset never depends on an empty phx-value surviving the round trip. It is
  # stored as NULL.
  def set_download_audio_language(%{"language" => "default"}, socket) do
    persist(socket, nil, "Download audio now follows the server default")
  end

  def set_download_audio_language(%{"language" => language}, socket) when is_binary(language) do
    persist(socket, language, "Download audio updated")
  end

  # A malformed event (no "language") is not a request to reset the choice.
  # Persisting nil here would silently clear a saved choice while reporting
  # success.
  def set_download_audio_language(_params, socket) do
    {:noreply, put_flash(socket, :error, "Could not save the download audio")}
  end

  defp persist(socket, language, message) do
    with :ok <- Authorization.authorize_update_media(socket) do
      media_item = socket.assigns.media_item

      case Media.update_media_item(media_item, %{download_audio_language: language},
             reason: "Download audio updated"
           ) do
        {:ok, updated} ->
          if updated.download_audio_language != media_item.download_audio_language do
            Upgrades.audio_preference_changed(updated)
          end

          {:noreply,
           socket
           |> assign(:media_item, %{
             media_item
             | download_audio_language: updated.download_audio_language
           })
           |> assign(:show_download_audio_modal, false)
           |> put_flash(:info, message)}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Could not save the download audio")}
      end
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end
end
