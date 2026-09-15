defmodule MydiaWeb.MediaLive.Show.AudioLanguageEvents do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Mydia.Media
  alias MydiaWeb.Live.Authorization

  def show_audio_language_modal(_params, socket) do
    {:noreply, assign(socket, :show_audio_language_modal, true)}
  end

  def hide_audio_language_modal(_params, socket) do
    {:noreply, assign(socket, :show_audio_language_modal, false)}
  end

  # Slots arrive keyed "0", "1", "2" so their order survives the form round
  # trip. Blank slots are dropped by MediaItem's normalization, and an all-blank
  # form stores nil, the same as resetting.
  def save_audio_languages(%{"audio_languages" => slots}, socket) when is_map(slots) do
    languages =
      slots
      |> Enum.sort_by(fn {slot, _code} -> slot end)
      |> Enum.map(fn {_slot, code} -> code end)

    persist(socket, languages, "Audio language updated")
  end

  # A malformed event (no "audio_languages" map) is not a request to reset the
  # override - reset_audio_languages/2 owns that. Persisting nil here would
  # silently clear a saved override while reporting success.
  def save_audio_languages(_params, socket) do
    {:noreply, put_flash(socket, :error, "Could not save the audio language")}
  end

  def reset_audio_languages(_params, socket) do
    persist(socket, nil, "Audio language now follows the server default")
  end

  defp persist(socket, languages, message) do
    with :ok <- Authorization.authorize_update_media(socket) do
      media_item = socket.assigns.media_item

      case Media.update_media_item(media_item, %{audio_languages: languages},
             reason: "Audio language updated"
           ) do
        {:ok, updated} ->
          {:noreply,
           socket
           |> assign(:media_item, %{media_item | audio_languages: updated.audio_languages})
           |> assign(:show_audio_language_modal, false)
           |> put_flash(:info, message)}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Could not save the audio language")}
      end
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end
end
