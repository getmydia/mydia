defmodule MydiaWeb.MediaLive.Index.LibraryActions do
  @moduledoc """
  The library page's single-purpose write actions, split out of
  `MydiaWeb.MediaLive.Index`. Callers check the user's role first; nothing
  here does.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, stream_insert: 3]

  alias Mydia.Media
  alias Mydia.Media.LibraryListing

  @spec toggle_monitored(Phoenix.LiveView.Socket.t(), String.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def toggle_monitored(socket, id) do
    case Media.list_media_items(socket.assigns.current_scope, ids: [id]) do
      [media_item] -> toggle_item(socket, media_item)
      [] -> {:noreply, put_flash(socket, :error, "Failed to update monitoring status")}
    end
  end

  defp toggle_item(socket, media_item) do
    id = media_item.id
    new_monitored_status = !media_item.monitored

    case Media.update_media_item(
           socket.assigns.current_scope,
           media_item,
           %{monitored: new_monitored_status},
           reason: if(new_monitored_status, do: "Monitoring enabled", else: "Monitoring disabled")
         ) do
      {:ok, _updated_item} ->
        socket =
          case LibraryListing.row(
                 socket.assigns.current_scope,
                 id,
                 socket.assigns.current_user.id
               ) do
            nil -> socket
            row -> stream_insert(socket, :media_items, row)
          end

        {:noreply,
         put_flash(
           socket,
           :info,
           "Monitoring #{if new_monitored_status, do: "enabled", else: "disabled"}"
         )}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to update monitoring status")}
    end
  end

  @spec start_scan(Phoenix.LiveView.Socket.t()) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def start_scan(socket) do
    case Mydia.Library.trigger_full_library_scan() do
      # The scan job is unique, so this insert can be deduped into a scan that is
      # already queued (the boot-time repair scan waits out a jitter delay before
      # it runs). Don't claim a scan started, and don't switch the UI into a
      # scanning state that no broadcast will ever clear.
      {:ok, %Oban.Job{conflict?: true}} ->
        {:noreply, put_flash(socket, :info, "A library scan is already queued")}

      {:ok, _job} ->
        {:noreply,
         socket
         |> assign(:scanning, true)
         |> assign(:scan_result, nil)
         |> assign(:scan_progress, nil)
         |> put_flash(:info, "Library scan started...")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to start library scan")}
    end
  end
end
