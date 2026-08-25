defmodule MydiaWeb.MediaLive.Show.LibraryEvents do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  import MydiaWeb.MediaLive.Show.Loaders, only: [assign_target_library: 2]

  alias Mydia.Media
  alias MydiaWeb.Live.Authorization

  def show_target_library_modal(_params, socket) do
    {:noreply, assign(socket, :show_target_library_modal, true)}
  end

  def hide_target_library_modal(_params, socket) do
    {:noreply, assign(socket, :show_target_library_modal, false)}
  end

  def update_target_library(%{"library-path-id" => raw_id}, socket) do
    with :ok <- Authorization.authorize_update_media(socket) do
      media_item = socket.assigns.media_item
      library_path_id = if raw_id == "", do: nil, else: raw_id

      case Media.update_media_item(
             media_item,
             %{library_path_id: library_path_id},
             reason: "Target library updated"
           ) do
        {:ok, updated} ->
          message =
            if library_path_id,
              do: "Future downloads will go to the selected library",
              else: "Library is now chosen automatically"

          media_item = %{media_item | library_path_id: updated.library_path_id}

          {:noreply,
           socket
           |> assign(:media_item, media_item)
           |> assign_target_library(media_item)
           |> assign(:show_target_library_modal, false)
           |> put_flash(:info, message)}

        {:error, _changeset} ->
          {:noreply,
           socket
           |> assign(:show_target_library_modal, false)
           |> put_flash(:error, "Failed to update the library")}
      end
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end
end
