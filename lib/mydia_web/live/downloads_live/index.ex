defmodule MydiaWeb.DownloadsLive.Index do
  use MydiaWeb, :live_view
  alias Mydia.Downloads
  alias Phoenix.PubSub

  @items_per_page 50

  @impl true
  def mount(_params, _session, socket) do
    # Subscribe to download updates for real-time progress
    if connected?(socket) do
      PubSub.subscribe(Mydia.PubSub, "downloads")
    end

    {:ok,
     socket
     |> assign(:page_title, "Activity")
     |> assign(:active_tab, :queue)
     |> assign(:selected_ids, MapSet.new())
     |> assign(:page, 0)
     |> assign(:has_more, true)
     |> load_downloads()}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    tab_atom = String.to_existing_atom(tab)

    {:noreply,
     socket
     |> assign(:active_tab, tab_atom)
     |> assign(:selected_ids, MapSet.new())
     |> assign(:page, 0)
     |> load_downloads()}
  end

  def handle_event("toggle_select", %{"id" => id}, socket) do
    selected_ids =
      if MapSet.member?(socket.assigns.selected_ids, id) do
        MapSet.delete(socket.assigns.selected_ids, id)
      else
        MapSet.put(socket.assigns.selected_ids, id)
      end

    {:noreply, assign(socket, :selected_ids, selected_ids)}
  end

  def handle_event("toggle_select_all", _params, socket) do
    selected_ids =
      if MapSet.size(socket.assigns.selected_ids) > 0 do
        MapSet.new()
      else
        # Select all visible downloads
        downloads = get_current_downloads(socket)
        downloads |> Enum.map(& &1.id) |> MapSet.new()
      end

    {:noreply, assign(socket, :selected_ids, selected_ids)}
  end

  def handle_event("cancel_download", %{"id" => id}, socket) do
    download = Downloads.get_download!(id)

    case Downloads.cancel_download(download) do
      {:ok, _updated} ->
        {:noreply,
         socket
         |> put_flash(:info, "Download cancelled")
         |> load_downloads()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to cancel download")}
    end
  end

  def handle_event("retry_download", %{"id" => id}, socket) do
    download = Downloads.get_download!(id)

    case Downloads.update_download(download, %{status: "pending", error_message: nil}) do
      {:ok, _updated} ->
        {:noreply,
         socket
         |> put_flash(:info, "Download queued for retry")
         |> load_downloads()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to retry download")}
    end
  end

  def handle_event("delete_download", %{"id" => id}, socket) do
    download = Downloads.get_download!(id)

    case Downloads.delete_download(download) do
      {:ok, _deleted} ->
        {:noreply,
         socket
         |> put_flash(:info, "Download removed")
         |> load_downloads()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to delete download")}
    end
  end

  def handle_event("batch_retry", _params, socket) do
    selected_ids = MapSet.to_list(socket.assigns.selected_ids)

    results =
      Enum.map(selected_ids, fn id ->
        download = Downloads.get_download!(id)
        Downloads.update_download(download, %{status: "pending", error_message: nil})
      end)

    success_count = Enum.count(results, fn {status, _} -> status == :ok end)

    {:noreply,
     socket
     |> assign(:selected_ids, MapSet.new())
     |> put_flash(:info, "#{success_count} download(s) queued for retry")
     |> load_downloads()}
  end

  def handle_event("batch_delete", _params, socket) do
    selected_ids = MapSet.to_list(socket.assigns.selected_ids)

    results =
      Enum.map(selected_ids, fn id ->
        download = Downloads.get_download!(id)
        Downloads.delete_download(download)
      end)

    success_count = Enum.count(results, fn {status, _} -> status == :ok end)

    {:noreply,
     socket
     |> assign(:selected_ids, MapSet.new())
     |> put_flash(:info, "#{success_count} download(s) removed")
     |> load_downloads()}
  end

  def handle_event("clear_completed", _params, socket) do
    # Delete all completed downloads
    completed_downloads = Downloads.list_downloads(status: "completed")

    results =
      Enum.map(completed_downloads, fn download ->
        Downloads.delete_download(download)
      end)

    success_count = Enum.count(results, fn {status, _} -> status == :ok end)

    {:noreply,
     socket
     |> put_flash(:info, "#{success_count} completed download(s) cleared")
     |> load_downloads()}
  end

  def handle_event("load_more", _params, socket) do
    if socket.assigns.has_more do
      {:noreply,
       socket
       |> update(:page, &(&1 + 1))
       |> load_downloads()}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:download_updated, _download_id}, socket) do
    # Reload downloads when we receive an update
    # In a real implementation, we might want to just update the specific download
    {:noreply, load_downloads(socket)}
  end

  # Private functions

  defp load_downloads(socket) do
    status_filter =
      case socket.assigns.active_tab do
        :queue -> ["pending", "downloading"]
        :issues -> "failed"
      end

    # Get all matching downloads for the current tab
    all_downloads =
      Downloads.list_downloads(status: status_filter, preload: [:media_item, :episode])

    # Apply pagination
    page = socket.assigns.page
    offset = page * @items_per_page
    paginated_downloads = all_downloads |> Enum.drop(offset) |> Enum.take(@items_per_page)
    has_more = length(all_downloads) > offset + @items_per_page

    # Determine if we need to append or reset stream
    reset? = page == 0

    socket
    |> assign(:has_more, has_more)
    |> assign(:downloads_empty?, reset? and paginated_downloads == [])
    |> stream(:downloads, paginated_downloads, reset: reset?)
  end

  defp get_current_downloads(socket) do
    status_filter =
      case socket.assigns.active_tab do
        :queue -> ["pending", "downloading"]
        :issues -> "failed"
      end

    Downloads.list_downloads(status: status_filter, preload: [:media_item, :episode])
  end

  # View helpers

  defp is_selected?(socket, id) do
    MapSet.member?(socket.assigns.selected_ids, id)
  end

  defp get_poster_url(download) do
    cond do
      download.media_item && download.media_item.metadata ->
        case download.media_item.metadata do
          %{"poster_path" => path} when is_binary(path) ->
            "https://image.tmdb.org/t/p/w200#{path}"

          _ ->
            "/images/no-poster.jpg"
        end

      true ->
        "/images/no-poster.jpg"
    end
  end

  defp format_speed(nil), do: "—"

  defp format_speed(bytes_per_second) when is_number(bytes_per_second) do
    cond do
      bytes_per_second >= 1_048_576 ->
        "#{Float.round(bytes_per_second / 1_048_576, 2)} MB/s"

      bytes_per_second >= 1024 ->
        "#{Float.round(bytes_per_second / 1024, 2)} KB/s"

      true ->
        "#{bytes_per_second} B/s"
    end
  end

  defp format_size(nil), do: "—"

  defp format_size(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_099_511_627_776 -> "#{Float.round(bytes / 1_099_511_627_776, 2)} TB"
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 2)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 2)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 2)} KB"
      true -> "#{bytes} B"
    end
  end

  defp format_eta(nil), do: "—"

  defp format_eta(%DateTime{} = dt) do
    now = DateTime.utc_now()
    diff = DateTime.diff(dt, now, :second)

    cond do
      diff < 0 -> "Now"
      diff < 60 -> "#{diff}s"
      diff < 3600 -> "#{div(diff, 60)}m"
      diff < 86400 -> "#{div(diff, 3600)}h"
      true -> "#{div(diff, 86400)}d"
    end
  end

  defp format_progress(nil), do: 0.0
  defp format_progress(progress), do: Float.round(progress, 1)

  defp get_metadata_value(download, key) do
    case download.metadata do
      %{^key => value} -> value
      _ -> nil
    end
  end

  defp status_badge_class(status) do
    case status do
      "completed" -> "badge-success"
      "failed" -> "badge-error"
      "cancelled" -> "badge-warning"
      "downloading" -> "badge-primary"
      "pending" -> "badge-info"
      _ -> "badge-ghost"
    end
  end

  defp get_display_title(download) do
    cond do
      download.media_item ->
        download.media_item.title

      download.episode ->
        "#{download.episode.title} (S#{download.episode.season_number}E#{download.episode.episode_number})"

      true ->
        download.title
    end
  end
end
