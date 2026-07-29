defmodule MydiaWeb.BooksLive.Index do
  use MydiaWeb, :live_view

  alias Mydia.Books

  @items_per_page 50
  @items_per_scroll 25

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:view_mode, :grid)
     |> assign(:search_query, "")
     |> assign(:filter_monitored, nil)
     |> assign(:filter_format, nil)
     |> assign(:sort_by, "title_asc")
     |> assign(:page, 0)
     |> assign(:has_more, true)
     |> assign(:page_title, "Books")
     |> stream(:books, [])}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, load_books(socket, reset: true)}
  end

  @impl true
  def handle_event("toggle_view", %{"mode" => mode}, socket) do
    view_mode = String.to_existing_atom(mode)

    {:noreply,
     socket
     |> assign(:view_mode, view_mode)
     |> assign(:page, 0)
     |> load_books(reset: true)}
  end

  def handle_event("search", params, socket) do
    query = params["search"] || params["value"] || ""

    {:noreply,
     socket
     |> assign(:search_query, query)
     |> assign(:page, 0)
     |> load_books(reset: true)}
  end

  def handle_event("filter", params, socket) do
    monitored =
      case params["monitored"] do
        "all" -> nil
        "true" -> true
        "false" -> false
        _ -> nil
      end

    format =
      case params["format"] do
        "" -> nil
        format -> format
      end

    sort_by = params["sort_by"] || socket.assigns.sort_by

    {:noreply,
     socket
     |> assign(:filter_monitored, monitored)
     |> assign(:filter_format, format)
     |> assign(:sort_by, sort_by)
     |> assign(:page, 0)
     |> load_books(reset: true)}
  end

  def handle_event("load_more", _params, socket) do
    if socket.assigns.has_more do
      {:noreply,
       socket
       |> update(:page, &(&1 + 1))
       |> load_books(reset: false)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_book_monitored", %{"id" => id}, socket) do
    book = Books.get_book!(id)
    new_monitored_status = !book.monitored

    case Books.update_book(book, %{monitored: new_monitored_status}) do
      {:ok, _updated_book} ->
        updated_book_with_preloads =
          Books.get_book!(id, preload: [:author, :book_files])

        {:noreply,
         socket
         |> stream_insert(:books, updated_book_with_preloads)
         |> put_flash(
           :info,
           "Monitoring #{if new_monitored_status, do: "enabled", else: "disabled"}"
         )}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to update monitoring status")}
    end
  end

  defp load_books(socket, opts) do
    reset? = Keyword.get(opts, :reset, false)
    page = if reset?, do: 0, else: socket.assigns.page
    offset = if page == 0, do: 0, else: @items_per_page + (page - 1) * @items_per_scroll
    limit = if page == 0, do: @items_per_page, else: @items_per_scroll

    query_opts =
      []
      |> maybe_add_filter(:monitored, socket.assigns.filter_monitored)
      |> maybe_add_filter(:search, socket.assigns.search_query)
      |> Keyword.put(:preload, [:author, :book_files])

    all_books = Books.list_books(query_opts)

    # Apply format filter client-side (since it's on the association)
    all_books = apply_format_filter(all_books, socket.assigns.filter_format)

    # Apply sorting
    books = apply_sorting(all_books, socket.assigns.sort_by)

    # Apply pagination
    paginated_books = books |> Enum.drop(offset) |> Enum.take(limit)
    has_more = length(books) > offset + limit

    socket =
      socket
      |> assign(:has_more, has_more)
      |> assign(:books_empty?, reset? and books == [])

    if reset? do
      stream(socket, :books, paginated_books, reset: true)
    else
      stream(socket, :books, paginated_books)
    end
  end

  defp maybe_add_filter(opts, _key, nil), do: opts
  defp maybe_add_filter(opts, _key, ""), do: opts
  defp maybe_add_filter(opts, key, value), do: Keyword.put(opts, key, value)

  defp apply_format_filter(books, nil), do: books

  defp apply_format_filter(books, format) do
    Enum.filter(books, fn book ->
      case book.book_files do
        files when is_list(files) ->
          Enum.any?(files, &(&1.format == format))

        _ ->
          false
      end
    end)
  end

  defp apply_sorting(books, sort_by) do
    case sort_by do
      "title_asc" ->
        Enum.sort_by(books, &String.downcase(&1.title || ""), :asc)

      "title_desc" ->
        Enum.sort_by(books, &String.downcase(&1.title || ""), :desc)

      "year_asc" ->
        Enum.sort_by(books, &get_year(&1), :asc)

      "year_desc" ->
        Enum.sort_by(books, &get_year(&1), :desc)

      "added_asc" ->
        Enum.sort_by(books, & &1.inserted_at, :asc)

      "added_desc" ->
        Enum.sort_by(books, & &1.inserted_at, :desc)

      "author_asc" ->
        Enum.sort_by(books, &get_author_name(&1), :asc)

      "author_desc" ->
        Enum.sort_by(books, &get_author_name(&1), :desc)

      "series_asc" ->
        books
        |> Enum.sort_by(fn book ->
          {book.series_name || "zzz", book.series_position || 999}
        end)

      _ ->
        Enum.sort_by(books, &String.downcase(&1.title || ""), :asc)
    end
  end

  defp get_year(%{publish_date: nil}), do: 0
  defp get_year(%{publish_date: date}), do: date.year

  defp get_author_name(%{author: %{name: name}}) when is_binary(name),
    do: String.downcase(name)

  defp get_author_name(_), do: ""

  defp get_cover_url(book) do
    if is_binary(book.cover_url) and book.cover_url != "" do
      book.cover_url
    else
      "/images/no-poster.svg"
    end
  end

  defp format_year(nil), do: "N/A"
  defp format_year(%Date{year: year}), do: year
  defp format_year(year), do: year

  defp get_format_badge(book) do
    case book.book_files do
      files when is_list(files) and files != [] ->
        formats =
          files
          |> Enum.map(& &1.format)
          |> Enum.reject(&is_nil/1)

        cond do
          "epub" in formats -> "EPUB"
          "pdf" in formats -> "PDF"
          "mobi" in formats -> "MOBI"
          formats != [] -> String.upcase(hd(formats))
          true -> nil
        end

      _ ->
        nil
    end
  end

  defp get_available_formats(book) do
    case book.book_files do
      files when is_list(files) ->
        files
        |> Enum.map(& &1.format)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.map(&String.upcase/1)

      _ ->
        []
    end
  end

  defp format_badge_class("EPUB"), do: "badge-success"
  defp format_badge_class("PDF"), do: "badge-warning"
  defp format_badge_class("MOBI"), do: "badge-info"
  defp format_badge_class("AZW3"), do: "badge-info"
  defp format_badge_class("CBZ"), do: "badge-secondary"
  defp format_badge_class("CBR"), do: "badge-secondary"
  defp format_badge_class(_), do: "badge-ghost"

  defp get_series_info(book) do
    if book.series_name do
      if book.series_position do
        "#{book.series_name} ##{format_series_position(book.series_position)}"
      else
        book.series_name
      end
    else
      nil
    end
  end

  defp format_series_position(position) when is_float(position) do
    if Float.floor(position) == position do
      trunc(position)
    else
      position
    end
  end

  defp format_series_position(position), do: position

  defp total_file_size(book) do
    case book.book_files do
      files when is_list(files) ->
        files
        |> Enum.map(& &1.size)
        |> Enum.reject(&is_nil/1)
        |> Enum.sum()

      _ ->
        0
    end
  end

  defp format_file_size(0), do: "-"
  defp format_file_size(nil), do: "-"

  defp format_file_size(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 2)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 2)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 2)} KB"
      true -> "#{bytes} B"
    end
  end
end
