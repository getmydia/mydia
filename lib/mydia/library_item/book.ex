defmodule Mydia.LibraryItem.Book do
  @moduledoc """
  LibraryItem implementation for Book.
  """
  @behaviour Mydia.LibraryItem

  @default_cover "/images/no-poster.svg"

  @impl Mydia.LibraryItem
  def display_title(%Mydia.Books.Book{title: title}), do: title

  @impl Mydia.LibraryItem
  def poster_url(%Mydia.Books.Book{cover_url: cover_url}) do
    if is_binary(cover_url) and cover_url != "" do
      cover_url
    else
      @default_cover
    end
  end

  @impl Mydia.LibraryItem
  def item_path(%Mydia.Books.Book{id: id}) do
    "/books/#{id}"
  end

  @impl Mydia.LibraryItem
  def metadata_badges(%Mydia.Books.Book{} = book) do
    badges = []

    # Add format badges for available formats
    badges =
      case book.book_files do
        files when is_list(files) and files != [] ->
          formats =
            files
            |> Enum.map(& &1.format)
            |> Enum.reject(&is_nil/1)
            |> Enum.uniq()

          format_badges =
            Enum.map(formats, fn format ->
              %{label: String.upcase(format), class: format_badge_class(format)}
            end)

          format_badges ++ badges

        _ ->
          badges
      end

    # Add series badge if part of a series
    badges =
      if book.series_name do
        series_label =
          if book.series_position do
            "#{book.series_name} ##{format_series_position(book.series_position)}"
          else
            book.series_name
          end

        [%{label: series_label, class: "badge-accent"} | badges]
      else
        badges
      end

    badges
  end

  @impl Mydia.LibraryItem
  def file_size(%Mydia.Books.Book{book_files: book_files}) when is_list(book_files) do
    book_files
    |> Enum.map(& &1.size)
    |> Enum.reject(&is_nil/1)
    |> Enum.sum()
  end

  def file_size(_), do: 0

  @impl Mydia.LibraryItem
  def year(%Mydia.Books.Book{publish_date: nil}), do: nil

  def year(%Mydia.Books.Book{publish_date: publish_date}) do
    publish_date.year
  end

  @impl Mydia.LibraryItem
  def item_type(%Mydia.Books.Book{}), do: "book"

  @impl Mydia.LibraryItem
  def monitored?(%Mydia.Books.Book{monitored: monitored}), do: monitored

  @impl Mydia.LibraryItem
  def quality_badge(%Mydia.Books.Book{book_files: book_files}) when is_list(book_files) do
    # Show preferred format as quality badge
    formats =
      book_files
      |> Enum.map(& &1.format)
      |> Enum.reject(&is_nil/1)

    # Prefer epub > pdf > mobi > others
    cond do
      "epub" in formats -> "EPUB"
      "pdf" in formats -> "PDF"
      "mobi" in formats -> "MOBI"
      formats != [] -> String.upcase(hd(formats))
      true -> nil
    end
  end

  def quality_badge(_), do: nil

  @impl Mydia.LibraryItem
  def secondary_text(%Mydia.Books.Book{author: author}) when not is_nil(author) do
    case author do
      %Mydia.Books.Author{name: name} -> name
      _ -> nil
    end
  end

  def secondary_text(_), do: nil

  @impl Mydia.LibraryItem
  def status(%Mydia.Books.Book{} = book) do
    has_files = has_book_files?(book)

    if has_files do
      {:complete, %{has_files: true}}
    else
      {:missing, %{has_files: false}}
    end
  end

  defp has_book_files?(%Mydia.Books.Book{book_files: files}) when is_list(files),
    do: files != []

  defp has_book_files?(_), do: false

  defp format_badge_class("epub"), do: "badge-success"
  defp format_badge_class("pdf"), do: "badge-warning"
  defp format_badge_class("mobi"), do: "badge-info"
  defp format_badge_class("azw3"), do: "badge-info"
  defp format_badge_class("cbz"), do: "badge-secondary"
  defp format_badge_class("cbr"), do: "badge-secondary"
  defp format_badge_class(_), do: "badge-ghost"

  defp format_series_position(position) when is_float(position) do
    if Float.floor(position) == position do
      trunc(position)
    else
      position
    end
  end

  defp format_series_position(position), do: position
end
