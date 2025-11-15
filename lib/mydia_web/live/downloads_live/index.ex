defmodule MydiaWeb.DownloadsLive.Index do
  use MydiaWeb, :live_view
  alias Mydia.Downloads
  alias Mydia.Downloads.Structs.DownloadMetadata
  alias Phoenix.PubSub
  alias MydiaWeb.Live.Authorization

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
     |> assign(:selection_mode, false)
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
     |> assign(:selection_mode, false)
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

    {:noreply,
     socket
     |> assign(:selected_ids, selected_ids)
     |> assign(:selection_mode, true)}
  end

  def handle_event("toggle_select_all", _params, socket) do
    if socket.assigns.selection_mode and MapSet.size(socket.assigns.selected_ids) > 0 do
      # Exit selection mode and clear selections
      {:noreply,
       socket
       |> assign(:selected_ids, MapSet.new())
       |> assign(:selection_mode, false)
       |> reload_stream()}
    else
      # Enter selection mode and select all visible downloads
      downloads = get_current_downloads(socket)
      selected_ids = downloads |> Enum.map(& &1.id) |> MapSet.new()

      {:noreply,
       socket
       |> assign(:selected_ids, selected_ids)
       |> assign(:selection_mode, true)
       |> reload_stream()}
    end
  end

  def handle_event("cancel_download", %{"id" => id}, socket) do
    with :ok <- Authorization.authorize_manage_downloads(socket) do
      download = Downloads.get_download!(id)

      case Downloads.cancel_download(download, delete_files: false) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, "Download cancelled and removed from client")
           |> load_downloads()}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to cancel download: #{inspect(reason)}")}
      end
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  def handle_event("pause_download", %{"id" => id}, socket) do
    with :ok <- Authorization.authorize_manage_downloads(socket) do
      download = Downloads.get_download!(id)

      case Downloads.pause_download(download) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, "Download paused")
           |> load_downloads()}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to pause download: #{inspect(reason)}")}
      end
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  def handle_event("resume_download", %{"id" => id}, socket) do
    with :ok <- Authorization.authorize_manage_downloads(socket) do
      download = Downloads.get_download!(id)

      case Downloads.resume_download(download) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, "Download resumed")
           |> load_downloads()}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to resume download: #{inspect(reason)}")}
      end
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  def handle_event("retry_download", %{"id" => id}, socket) do
    with :ok <- Authorization.authorize_manage_downloads(socket) do
      download = Downloads.get_download!(id, preload: [:media_item, :episode])

      # Clear error message if any
      case Downloads.update_download(download, %{error_message: nil}) do
        {:ok, updated} ->
          # Convert metadata to struct for type-safe access
          metadata = DownloadMetadata.from_map(updated.metadata)

          # Re-add to client using the original download URL
          search_result = %Mydia.Indexers.SearchResult{
            download_url: updated.download_url,
            title: updated.title,
            indexer: updated.indexer,
            size: metadata.size,
            seeders: metadata.seeders,
            leechers: metadata.leechers,
            quality: metadata.quality
          }

          opts =
            []
            |> maybe_add_opt(:media_item_id, updated.media_item_id)
            |> maybe_add_opt(:episode_id, updated.episode_id)
            |> maybe_add_opt(:client_name, updated.download_client)

          # Delete old download record and create new one
          Downloads.delete_download(updated)

          case Downloads.initiate_download(search_result, opts) do
            {:ok, _new_download} ->
              {:noreply,
               socket
               |> put_flash(:info, "Download re-initiated")
               |> load_downloads()}

            {:error, reason} ->
              {:noreply,
               put_flash(socket, :error, "Failed to retry download: #{inspect(reason)}")}
          end

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Failed to update download")}
      end
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  def handle_event("delete_download", %{"id" => id}, socket) do
    with :ok <- Authorization.authorize_manage_downloads(socket) do
      download = Downloads.get_download!(id)

      # First try to remove from client (ignore errors if already removed)
      _ = Downloads.cancel_download(download, delete_files: true)

      # Then delete from database
      case Downloads.delete_download(download) do
        {:ok, _deleted} ->
          {:noreply,
           socket
           |> put_flash(:info, "Download removed")
           |> load_downloads()}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Failed to delete download")}
      end
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  def handle_event("batch_retry", _params, socket) do
    selected_ids = MapSet.to_list(socket.assigns.selected_ids)

    results =
      Enum.map(selected_ids, fn id ->
        try do
          download = Downloads.get_download!(id, preload: [:media_item, :episode])

          # Convert metadata to struct for type-safe access
          metadata = DownloadMetadata.from_map(download.metadata)

          search_result = %Mydia.Indexers.SearchResult{
            download_url: download.download_url,
            title: download.title,
            indexer: download.indexer,
            size: metadata.size,
            seeders: metadata.seeders,
            leechers: metadata.leechers,
            quality: metadata.quality
          }

          opts =
            []
            |> maybe_add_opt(:media_item_id, download.media_item_id)
            |> maybe_add_opt(:episode_id, download.episode_id)
            |> maybe_add_opt(:client_name, download.download_client)

          Downloads.delete_download(download)
          Downloads.initiate_download(search_result, opts)
        rescue
          _ -> {:error, :failed}
        end
      end)

    success_count = Enum.count(results, fn {status, _} -> status == :ok end)

    {:noreply,
     socket
     |> assign(:selected_ids, MapSet.new())
     |> assign(:selection_mode, false)
     |> put_flash(:info, "#{success_count} download(s) re-initiated")
     |> load_downloads()}
  end

  def handle_event("batch_delete", _params, socket) do
    selected_ids = MapSet.to_list(socket.assigns.selected_ids)

    results =
      Enum.map(selected_ids, fn id ->
        try do
          download = Downloads.get_download!(id)
          # Try to remove from client (ignore errors)
          _ = Downloads.cancel_download(download, delete_files: true)
          # Delete from database
          Downloads.delete_download(download)
        rescue
          _ -> {:error, :failed}
        end
      end)

    success_count = Enum.count(results, fn {status, _} -> status == :ok end)

    {:noreply,
     socket
     |> assign(:selected_ids, MapSet.new())
     |> assign(:selection_mode, false)
     |> put_flash(:info, "#{success_count} download(s) removed")
     |> load_downloads()}
  end

  def handle_event("clear_completed", _params, socket) do
    # Get all completed downloads from clients
    completed_downloads = Downloads.list_downloads_with_status(filter: :completed)

    results =
      Enum.map(completed_downloads, fn download_map ->
        try do
          download = Downloads.get_download!(download_map.id)
          # Try to remove from client (ignore errors as may already be removed)
          _ = Downloads.cancel_download(download, delete_files: false)
          # Delete from database
          Downloads.delete_download(download)
        rescue
          _ -> {:error, :failed}
        end
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

  defp reload_stream(socket) do
    downloads = get_current_downloads(socket)
    stream(socket, :downloads, downloads, reset: true)
  end

  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp load_downloads(socket) do
    filter =
      case socket.assigns.active_tab do
        :queue -> :active
        :issues -> :failed
      end

    # Get all matching downloads for the current tab with real-time status from clients
    all_downloads = Downloads.list_downloads_with_status(filter: filter)

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
    filter =
      case socket.assigns.active_tab do
        :queue -> :active
        :issues -> :failed
      end

    Downloads.list_downloads_with_status(filter: filter)
  end

  # View helpers

  defp is_selected?(assigns, id) do
    MapSet.member?(assigns.selected_ids, id)
  end

  defp get_poster_url(download) do
    cond do
      is_map(download.media_item) && is_map(download.media_item.metadata) ->
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

  defp format_eta(seconds) when is_integer(seconds) do
    cond do
      seconds < 0 -> "Now"
      seconds < 60 -> "#{seconds}s"
      seconds < 3600 -> "#{div(seconds, 60)}m"
      seconds < 86400 -> "#{div(seconds, 3600)}h"
      true -> "#{div(seconds, 86400)}d"
    end
  end

  defp format_progress(nil), do: 0.0
  defp format_progress(progress), do: Float.round(progress, 1)

  defp get_metadata_value(download, key) do
    # Convert metadata to struct for type-safe access
    metadata = DownloadMetadata.from_map(download.metadata)

    if metadata do
      case key do
        "size" -> metadata.size
        "seeders" -> metadata.seeders
        "leechers" -> metadata.leechers
        "quality" -> metadata.quality
        "season_pack" -> metadata.season_pack
        "season_number" -> metadata.season_number
        "download_protocol" -> metadata.download_protocol
        _ -> nil
      end
    else
      nil
    end
  end

  defp status_badge_class(status) do
    case status do
      "completed" -> "badge-success"
      "seeding" -> "badge-success"
      "failed" -> "badge-error"
      "missing" -> "badge-error"
      "cancelled" -> "badge-warning"
      "downloading" -> "badge-primary"
      "checking" -> "badge-info"
      "paused" -> "badge-warning"
      _ -> "badge-ghost"
    end
  end

  defp get_display_title(download) do
    cond do
      # Episode download - show parent show title
      is_map(download.episode) ->
        if is_map(download.episode.media_item) do
          download.episode.media_item.title
        else
          # Fallback to direct media_item if episode.media_item is not loaded
          if is_map(download.media_item), do: download.media_item.title, else: "Unknown Show"
        end

      # Movie or show-level download
      is_map(download.media_item) && download.media_item.title ->
        download.media_item.title

      # Fallback to torrent title
      true ->
        download.title
    end
  end

  defp get_episode_details(download) do
    cond do
      # Download has a specific episode association
      is_map(download.episode) ->
        episode_id = format_episode_identifier(download.episode)
        episode_title = download.episode.title

        if episode_title do
          "#{episode_id} - #{episode_title}"
        else
          episode_id
        end

      # Download is for a TV show but no episode (likely season pack or series)
      is_map(download.media_item) && download.media_item.type == "tv_show" ->
        extract_season_info_from_title(download.title)

      true ->
        nil
    end
  end

  defp extract_season_info_from_title(title) do
    cond do
      # Match S01, S02, etc. (most common format)
      Regex.match?(~r/\.S(\d{1,2})(?:\.|E|$)/i, title) ->
        [_, season] = Regex.run(~r/\.S(\d{1,2})(?:\.|E|$)/i, title)
        "Season #{String.to_integer(season)}"

      # Match "Season 1", "Season 01", etc.
      Regex.match?(~r/Season[\s\.]+(\d{1,2})/i, title) ->
        [_, season] = Regex.run(~r/Season[\s\.]+(\d{1,2})/i, title)
        "Season #{String.to_integer(season)}"

      # If title has "Complete" or "Series" - likely full series pack
      Regex.match?(~r/(Complete|Series|Collection)/i, title) ->
        "Complete Series"

      # Fallback
      true ->
        nil
    end
  end

  defp format_episode_identifier(episode) do
    season = String.pad_leading("#{episode.season_number}", 2, "0")
    episode_num = String.pad_leading("#{episode.episode_number}", 2, "0")
    "S#{season}E#{episode_num}"
  end

  defp get_media_type(download) do
    cond do
      # If there's an episode, it's a TV show
      is_map(download.episode) ->
        "tv_show"

      # Otherwise check media_item type
      is_map(download.media_item) && download.media_item.type ->
        download.media_item.type

      # Unknown/fallback
      true ->
        nil
    end
  end

  defp media_type_badge(download) do
    case get_media_type(download) do
      "movie" -> {"🎬", "Movie", "badge-accent"}
      "tv_show" -> {"📺", "TV Show", "badge-info"}
      _ -> nil
    end
  end
end
