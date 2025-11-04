defmodule MydiaWeb.MediaLive.Index do
  use MydiaWeb, :live_view
  alias Mydia.Media

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
    |> Keyword.put(:preload, [:media_files])
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
end
