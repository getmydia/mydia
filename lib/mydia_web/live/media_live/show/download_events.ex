defmodule MydiaWeb.MediaLive.Show.DownloadEvents do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Mydia.Downloads
  alias Mydia.Indexers.SearchResult
  alias MydiaWeb.Live.Authorization

  import MydiaWeb.MediaLive.Show.Loaders,
    only: [load_media_item: 1, load_downloads_with_status: 1]

  import MydiaWeb.MediaLive.Show.Helpers, only: [maybe_add_opt: 3]

  require Logger

  def show_download_cancel_confirm(%{"download-id" => download_id}, socket) do
    download = Downloads.get_download!(download_id)

    {:noreply,
     socket
     |> assign(:show_download_cancel_confirm, true)
     |> assign(:download_to_cancel, download)}
  end

  def hide_download_cancel_confirm(_params, socket) do
    {:noreply,
     socket
     |> assign(:show_download_cancel_confirm, false)
     |> assign(:download_to_cancel, nil)}
  end

  def cancel_download(_params, socket) do
    download = socket.assigns.download_to_cancel

    case Downloads.cancel_download(download) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:show_download_cancel_confirm, false)
         |> assign(:download_to_cancel, nil)
         |> put_flash(:info, "Download cancelled")}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to cancel download")
         |> assign(:show_download_cancel_confirm, false)
         |> assign(:download_to_cancel, nil)}
    end
  end

  def show_download_delete_confirm(%{"download-id" => download_id}, socket) do
    download = Downloads.get_download!(download_id)

    {:noreply,
     socket
     |> assign(:show_download_delete_confirm, true)
     |> assign(:download_to_delete, download)}
  end

  def hide_download_delete_confirm(_params, socket) do
    {:noreply,
     socket
     |> assign(:show_download_delete_confirm, false)
     |> assign(:download_to_delete, nil)}
  end

  def delete_download_record(_params, socket) do
    download = socket.assigns.download_to_delete

    case Downloads.delete_download(download) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:media_item, load_media_item(socket.assigns.media_item.id))
         |> assign(:show_download_delete_confirm, false)
         |> assign(:download_to_delete, nil)
         |> put_flash(:info, "Download removed from history")}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to delete download")
         |> assign(:show_download_delete_confirm, false)
         |> assign(:download_to_delete, nil)}
    end
  end

  def show_download_details(%{"download-id" => download_id}, socket) do
    download = Downloads.get_download!(download_id)

    {:noreply,
     socket
     |> assign(:show_download_details_modal, true)
     |> assign(:download_details, download)}
  end

  def hide_download_details(_params, socket) do
    {:noreply,
     socket
     |> assign(:show_download_details_modal, false)
     |> assign(:download_details, nil)}
  end

  def retry_download(%{"download-id" => download_id}, socket) do
    download = Downloads.get_download!(download_id, preload: [:media_item, :episode])

    case Downloads.update_download(download, %{error_message: nil}) do
      {:ok, updated} ->
        search_result = %SearchResult{
          download_url: updated.download_url,
          title: updated.title,
          indexer: updated.indexer,
          size: updated.metadata["size"],
          seeders: updated.metadata["seeders"],
          leechers: updated.metadata["leechers"],
          quality: updated.metadata["quality"]
        }

        opts =
          []
          |> maybe_add_opt(:media_item_id, updated.media_item_id)
          |> maybe_add_opt(:episode_id, updated.episode_id)
          |> maybe_add_opt(:client_name, updated.download_client)

        Downloads.delete_download(updated)

        case Downloads.initiate_download(search_result, opts) do
          {:ok, _new_download} ->
            {:noreply, put_flash(socket, :info, "Download re-initiated")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Failed to retry download: #{inspect(reason)}")}
        end

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to update download")}
    end
  end

  @doc false
  # Deletes a failed-grab record from the header alert. No confirm modal: the
  # record never reached a client, so there is nothing to clean up remotely.
  def dismiss_failed_grab(%{"id" => id}, socket) do
    with :ok <- Authorization.authorize_manage_downloads(socket) do
      download = Downloads.get_download!(id)
      {:ok, _} = Downloads.delete_download(download)

      {:noreply,
       assign(
         socket,
         :downloads_with_status,
         load_downloads_with_status(socket.assigns.media_item)
       )}
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end
end
