defmodule MydiaWeb.MediaLive.Index do
  use MydiaWeb, :live_view
  alias Mydia.Media
  alias Mydia.Media.EpisodeStatus
  alias Mydia.Settings

  @items_per_page 50
  @items_per_scroll 25

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:view_mode, :grid)
     |> assign(:search_query, "")
     |> assign(:filter_monitored, nil)
     |> assign(:filter_quality, nil)
     |> assign(:page, 0)
     |> assign(:has_more, true)
     |> assign(:selection_mode, false)
     |> assign(:selected_ids, MapSet.new())
     |> assign(:show_delete_modal, false)
     |> assign(:show_batch_edit_modal, false)
     |> assign(:quality_profiles, [])
     |> assign(:batch_edit_form, to_form(%{}, as: :batch_edit))
     |> stream(:media_items, [])}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Media Library")
    |> assign(:filter_type, nil)
    |> load_media_items(reset: true)
  end

  defp apply_action(socket, :movies, _params) do
    socket
    |> assign(:page_title, "Movies")
    |> assign(:filter_type, "movie")
    |> load_media_items(reset: true)
  end

  defp apply_action(socket, :tv_shows, _params) do
    socket
    |> assign(:page_title, "TV Shows")
    |> assign(:filter_type, "tv_show")
    |> load_media_items(reset: true)
  end

  @impl true
  def handle_event("toggle_view", %{"mode" => mode}, socket) do
    view_mode = String.to_existing_atom(mode)
    {:noreply, assign(socket, :view_mode, view_mode)}
  end

  def handle_event("search", %{"search" => query}, socket) do
    {:noreply,
     socket
     |> assign(:search_query, query)
     |> assign(:page, 0)
     |> assign(:selected_ids, MapSet.new())
     |> load_media_items(reset: true)}
  end

  def handle_event("filter", params, socket) do
    monitored =
      case params["monitored"] do
        "all" -> nil
        "true" -> true
        "false" -> false
        _ -> nil
      end

    quality =
      case params["quality"] do
        "" -> nil
        q when q in ["720p", "1080p", "2160p"] -> q
        _ -> nil
      end

    {:noreply,
     socket
     |> assign(:filter_monitored, monitored)
     |> assign(:filter_quality, quality)
     |> assign(:page, 0)
     |> assign(:selected_ids, MapSet.new())
     |> load_media_items(reset: true)}
  end

  def handle_event("load_more", _params, socket) do
    if socket.assigns.has_more do
      {:noreply,
       socket
       |> update(:page, &(&1 + 1))
       |> load_media_items(reset: false)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_select", %{"id" => id}, socket) do
    selected_ids = socket.assigns.selected_ids

    updated_ids =
      if MapSet.member?(selected_ids, id) do
        MapSet.delete(selected_ids, id)
      else
        MapSet.put(selected_ids, id)
      end

    {:noreply, assign(socket, :selected_ids, updated_ids)}
  end

  def handle_event("select_all", _params, socket) do
    # Get all visible item IDs from the current stream
    # Note: We need to collect all currently loaded items
    query_opts = build_query_opts(socket.assigns)
    items = Media.list_media_items(query_opts)
    items = apply_search_filter(items, socket.assigns.search_query)
    items = apply_quality_filter(items, socket.assigns.filter_quality)

    all_ids = MapSet.new(items, & &1.id)

    {:noreply, assign(socket, :selected_ids, all_ids)}
  end

  def handle_event("clear_selection", _params, socket) do
    {:noreply, assign(socket, :selected_ids, MapSet.new())}
  end

  def handle_event("toggle_selection_mode", _params, socket) do
    selection_mode = !socket.assigns.selection_mode

    socket =
      if !selection_mode do
        # Exiting selection mode - clear selection
        assign(socket, :selected_ids, MapSet.new())
      else
        socket
      end

    {:noreply, assign(socket, :selection_mode, selection_mode)}
  end

  def handle_event("keydown", %{"key" => "Escape"}, socket) do
    {:noreply,
     socket
     |> assign(:selection_mode, false)
     |> assign(:selected_ids, MapSet.new())}
  end

  def handle_event("keydown", %{"key" => "a", "ctrlKey" => true}, socket) do
    # Ctrl+A - select all
    query_opts = build_query_opts(socket.assigns)
    items = Media.list_media_items(query_opts)
    items = apply_search_filter(items, socket.assigns.search_query)
    items = apply_quality_filter(items, socket.assigns.filter_quality)

    all_ids = MapSet.new(items, & &1.id)

    {:noreply, assign(socket, :selected_ids, all_ids)}
  end

  def handle_event("keydown", _params, socket) do
    # Ignore other key events
    {:noreply, socket}
  end

  def handle_event("batch_monitor", _params, socket) do
    selected_ids = MapSet.to_list(socket.assigns.selected_ids)

    case Media.update_media_items_monitored(selected_ids, true) do
      {:ok, count} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{count} #{pluralize_items(count)} set to monitored")
         |> assign(:selection_mode, false)
         |> assign(:selected_ids, MapSet.new())
         |> load_media_items(reset: true)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to update items")}
    end
  end

  def handle_event("batch_unmonitor", _params, socket) do
    selected_ids = MapSet.to_list(socket.assigns.selected_ids)

    case Media.update_media_items_monitored(selected_ids, false) do
      {:ok, count} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{count} #{pluralize_items(count)} set to unmonitored")
         |> assign(:selection_mode, false)
         |> assign(:selected_ids, MapSet.new())
         |> load_media_items(reset: true)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to update items")}
    end
  end

  def handle_event("batch_download", _params, socket) do
    # TODO: Implement download functionality
    # For now, just show a placeholder message
    {:noreply, put_flash(socket, :info, "Download functionality coming soon")}
  end

  def handle_event("show_delete_confirmation", _params, socket) do
    {:noreply, assign(socket, :show_delete_modal, true)}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :show_delete_modal, false)}
  end

  def handle_event("batch_delete_confirmed", _params, socket) do
    selected_ids = MapSet.to_list(socket.assigns.selected_ids)

    case Media.delete_media_items(selected_ids) do
      {:ok, count} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{count} #{pluralize_items(count)} deleted successfully")
         |> assign(:selection_mode, false)
         |> assign(:selected_ids, MapSet.new())
         |> assign(:show_delete_modal, false)
         |> load_media_items(reset: true)}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to delete items")
         |> assign(:show_delete_modal, false)}
    end
  end

  def handle_event("show_batch_edit", _params, socket) do
    quality_profiles = Settings.list_quality_profiles()

    {:noreply,
     socket
     |> assign(:quality_profiles, quality_profiles)
     |> assign(:show_batch_edit_modal, true)
     |> assign(:batch_edit_form, to_form(%{}, as: :batch_edit))}
  end

  def handle_event("cancel_batch_edit", _params, socket) do
    {:noreply, assign(socket, :show_batch_edit_modal, false)}
  end

  def handle_event("batch_edit_submit", %{"batch_edit" => params}, socket) do
    selected_ids = MapSet.to_list(socket.assigns.selected_ids)

    # Build attrs map with only non-empty values
    attrs =
      %{}
      |> maybe_add_attr(:quality_profile_id, params["quality_profile_id"])
      |> maybe_add_attr(:monitored, params["monitored"])

    case Media.update_media_items_batch(selected_ids, attrs) do
      {:ok, count} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{count} #{pluralize_items(count)} updated successfully")
         |> assign(:selection_mode, false)
         |> assign(:selected_ids, MapSet.new())
         |> assign(:show_batch_edit_modal, false)
         |> load_media_items(reset: true)}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to update items")
         |> assign(:show_batch_edit_modal, false)}
    end
  end

  defp load_media_items(socket, opts) do
    reset? = Keyword.get(opts, :reset, false)
    page = if reset?, do: 0, else: socket.assigns.page
    offset = if page == 0, do: 0, else: @items_per_page + (page - 1) * @items_per_scroll
    limit = if page == 0, do: @items_per_page, else: @items_per_scroll

    query_opts = build_query_opts(socket.assigns)
    items = Media.list_media_items(query_opts)

    # Apply search filtering (client-side for now)
    items = apply_search_filter(items, socket.assigns.search_query)

    # Apply quality filtering (client-side for now)
    items = apply_quality_filter(items, socket.assigns.filter_quality)

    # Apply pagination
    paginated_items = items |> Enum.drop(offset) |> Enum.take(limit)
    has_more = length(items) > offset + limit

    socket
    |> assign(:has_more, has_more)
    |> assign(:media_items_empty?, reset? and paginated_items == [])
    |> stream(:media_items, paginated_items, reset: reset?)
  end

  defp build_query_opts(assigns) do
    []
    |> maybe_add_filter(:type, assigns.filter_type)
    |> maybe_add_filter(:monitored, assigns.filter_monitored)
    |> Keyword.put(:preload, [:media_files, :downloads, episodes: [:media_files, :downloads]])
  end

  defp maybe_add_filter(opts, _key, nil), do: opts
  defp maybe_add_filter(opts, key, value), do: Keyword.put(opts, key, value)

  defp apply_search_filter(items, ""), do: items

  defp apply_search_filter(items, query) do
    query_lower = String.downcase(query)

    Enum.filter(items, fn item ->
      String.contains?(String.downcase(item.title), query_lower) or
        (item.original_title &&
           String.contains?(String.downcase(item.original_title), query_lower))
    end)
  end

  defp apply_quality_filter(items, nil), do: items

  defp apply_quality_filter(items, quality) do
    Enum.filter(items, fn item ->
      item.media_files
      |> Enum.any?(fn file -> file.quality == quality end)
    end)
  end

  defp get_poster_url(media_item) do
    case media_item.metadata do
      %{"poster_path" => path} when is_binary(path) ->
        "https://image.tmdb.org/t/p/w500#{path}"

      _ ->
        "/images/no-poster.jpg"
    end
  end

  defp format_year(nil), do: "N/A"
  defp format_year(year), do: year

  defp get_quality_badge(media_item) do
    case media_item.media_files do
      [] ->
        nil

      files ->
        # Get the highest quality from available files
        files
        |> Enum.map(& &1.quality)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort(:desc)
        |> List.first()
    end
  end

  defp format_file_size(nil), do: "N/A"

  defp format_file_size(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_099_511_627_776 -> "#{Float.round(bytes / 1_099_511_627_776, 2)} TB"
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 2)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 2)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 2)} KB"
      true -> "#{bytes} B"
    end
  end

  defp total_file_size(media_item) do
    media_item.media_files
    |> Enum.map(& &1.size)
    |> Enum.reject(&is_nil/1)
    |> Enum.sum()
  end

  defp item_selected?(selected_ids, item_id) do
    MapSet.member?(selected_ids, item_id)
  end

  defp pluralize_items(1), do: "item"
  defp pluralize_items(_), do: "items"

  defp maybe_add_attr(attrs, _key, nil), do: attrs
  defp maybe_add_attr(attrs, _key, ""), do: attrs
  defp maybe_add_attr(attrs, _key, "no_change"), do: attrs

  defp maybe_add_attr(attrs, key, value) do
    Map.put(attrs, key, value)
  end

  # Media status helpers
  defp get_media_item_status(media_item) do
    Media.get_media_status(media_item)
  end

  defp media_status_color(status) do
    EpisodeStatus.status_color(status)
  end

  defp media_status_icon(status) do
    EpisodeStatus.status_icon(status)
  end

  defp media_status_label(status) do
    EpisodeStatus.status_label(status)
  end

  defp format_episode_count(nil), do: nil

  defp format_episode_count(%{downloaded: downloaded, total: total}) do
    "#{downloaded}/#{total} episodes"
  end
end
