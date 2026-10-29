defmodule Mydia.Indexers.Cardigann.Result.Transform do
  @moduledoc false
  # Extracted row values to `SearchResult`s: the title and a download (or a
  # magnet built from the infohash) are required, links resolve against the
  # search URL, sizes and counts parse to integers, and the site category maps
  # to a Torznab one. A row missing its title or download yields no result.

  alias Mydia.Downloads.TorrentHash
  alias Mydia.Indexers.Cardigann.LinkResolver
  alias Mydia.Indexers.Cardigann.Result.Context
  alias Mydia.Indexers.CategoryMapping
  alias Mydia.Indexers.QualityParser
  alias Mydia.Indexers.SearchResult

  @spec search_results([%{String.t() => String.t()}], Context.t()) :: [SearchResult.t()]
  def search_results(rows, %Context{} = ctx) do
    rows
    |> Enum.map(&transform_to_search_result(&1, ctx))
    |> Enum.reject(&is_nil/1)
  end

  defp transform_to_search_result(row, %Context{} = ctx) do
    raw_size = get_field(row, "size", "0")

    with {:ok, title} <- get_required_field(row, "title"),
         {:ok, download_url} <- get_download_or_magnet(row, title) do
      resolved_download_url = LinkResolver.resolve(download_url, ctx.base_url)
      resolved_info_url = LinkResolver.resolve(get_field(row, "details"), ctx.base_url)

      %SearchResult{
        title: title,
        size: parse_size_with_title_fallback(raw_size, title),
        seeders: parse_integer(get_field(row, "seeders", "0")),
        leechers: parse_integer(get_field(row, "leechers", "0")),
        download_url: resolved_download_url,
        info_url: resolved_info_url,
        indexer: ctx.indexer_name,
        category: map_category(get_field(row, "category"), ctx.category_mappings),
        published_at: parse_date(get_field(row, "date")),
        quality: QualityParser.parse(title),
        tmdb_id: parse_optional_integer(get_field(row, "tmdbid")),
        imdb_id: get_field(row, "imdbid"),
        download_protocol: detect_download_protocol(resolved_download_url),
        guid: release_guid(row, resolved_download_url, resolved_info_url, ctx)
      }
    else
      _ -> nil
    end
  end

  # Prowlarr's CleanupReleases fills an unset guid from the release's download
  # URL, then a torrent's magnet, then its details URL. The download field wins
  # even when the infohash supplies the download URL, as on YTS.
  defp release_guid(row, download_url, info_url, ctx) do
    case get_required_field(row, "download") do
      {:ok, url} -> LinkResolver.resolve(url, ctx.base_url)
      {:error, _} -> download_url || info_url
    end
  end

  # Maps a site-specific category to a Torznab category ID; a value with no
  # mapping may already be a Torznab ID.
  defp map_category(nil, _category_mappings), do: nil
  defp map_category("", _category_mappings), do: nil

  defp map_category(raw_category, category_mappings)
       when is_list(category_mappings) and category_mappings != [] do
    CategoryMapping.map_site_category_to_torznab(raw_category, category_mappings) ||
      parse_integer(raw_category)
  end

  defp map_category(raw_category, _category_mappings), do: parse_integer(raw_category)

  # Infohash is preferred because some indexers (e.g. YTS) return HTML
  # instead of a .torrent file at the download URL.
  defp get_download_or_magnet(row, title) do
    case get_required_field(row, "infohash") do
      {:ok, hash} when byte_size(hash) >= 32 ->
        case TorrentHash.build_magnet(hash, title) do
          nil -> try_download_field(row)
          magnet -> {:ok, magnet}
        end

      _ ->
        try_download_field(row)
    end
  end

  defp try_download_field(row) do
    case get_required_field(row, "download") do
      {:ok, url} -> {:ok, url}
      {:error, _} -> {:error, :no_download_or_infohash}
    end
  end

  defp get_required_field(row, field) do
    case Map.get(row, field) do
      nil -> {:error, :missing_field}
      "" -> {:error, :empty_field}
      value -> {:ok, value}
    end
  end

  defp get_field(row, field, default \\ nil), do: Map.get(row, field) || default

  @spec parse_size_with_title_fallback(String.t() | nil, String.t()) :: non_neg_integer()
  def parse_size_with_title_fallback(raw_size, title) do
    case parse_size(raw_size) do
      0 -> extract_size_from_text(title)
      size -> size
    end
  end

  # Extracts size from text containing embedded size like "(3.05Gb)" or "500MB"
  defp extract_size_from_text(text) when is_binary(text) do
    case Regex.run(~r/([\d.]+)\s*(gb|gib|mb|mib|kb|kib|tb|tib)/i, text) do
      [_, num_str, unit] ->
        case Float.parse(num_str) do
          {num, _} -> trunc(num * size_unit_multiplier(String.downcase(unit)))
          :error -> 0
        end

      nil ->
        0
    end
  end

  defp extract_size_from_text(_), do: 0

  defp size_unit_multiplier("tb"), do: 1024 * 1024 * 1024 * 1024
  defp size_unit_multiplier("tib"), do: 1024 * 1024 * 1024 * 1024
  defp size_unit_multiplier("gb"), do: 1024 * 1024 * 1024
  defp size_unit_multiplier("gib"), do: 1024 * 1024 * 1024
  defp size_unit_multiplier("mb"), do: 1024 * 1024
  defp size_unit_multiplier("mib"), do: 1024 * 1024
  defp size_unit_multiplier("kb"), do: 1024
  defp size_unit_multiplier("kib"), do: 1024
  defp size_unit_multiplier(_), do: 1

  @spec parse_size(String.t() | nil) :: non_neg_integer()
  def parse_size(nil), do: 0
  def parse_size(""), do: 0

  def parse_size(size_str) when is_binary(size_str) do
    size_str = String.trim(size_str)
    size_str_lower = String.downcase(size_str)

    cond do
      String.contains?(size_str_lower, "gb") || String.contains?(size_str_lower, "gib") ->
        parse_size_value(size_str, 1024 * 1024 * 1024)

      String.contains?(size_str_lower, "mb") || String.contains?(size_str_lower, "mib") ->
        parse_size_value(size_str, 1024 * 1024)

      String.contains?(size_str_lower, "kb") || String.contains?(size_str_lower, "kib") ->
        parse_size_value(size_str, 1024)

      String.contains?(size_str_lower, "tb") || String.contains?(size_str_lower, "tib") ->
        parse_size_value(size_str, 1024 * 1024 * 1024 * 1024)

      true ->
        parse_integer(size_str)
    end
  end

  defp parse_size_value(size_str, multiplier) do
    # A number right before the unit, as in "3.05Gb" or "500 MB"; otherwise
    # every digit and period in the string.
    numeric_part =
      case Regex.run(~r/([\d.]+)\s*(?:gb|gib|mb|mib|kb|kib|tb|tib)/i, size_str) do
        [_, num] -> num
        nil -> size_str |> String.replace(~r/[^\d.]/, "") |> String.trim()
      end

    case Float.parse(numeric_part) do
      {value, _} -> trunc(value * multiplier)
      :error -> 0
    end
  end

  defp parse_integer(nil), do: 0
  defp parse_integer(""), do: 0

  defp parse_integer(str) when is_binary(str) do
    case Integer.parse(String.replace(str, ~r/[^\d]/, "")) do
      {num, _} -> num
      :error -> 0
    end
  end

  defp parse_integer(num) when is_integer(num), do: num
  defp parse_integer(_), do: 0

  # Prowlarr decodes an absent or zero id back to nil, so it never claims an id
  # the release does not have.
  defp parse_optional_integer(value) do
    case parse_integer(value) do
      0 -> nil
      number -> number
    end
  end

  @spec parse_date(String.t() | nil) :: DateTime.t() | nil
  def parse_date(nil), do: nil
  def parse_date(""), do: nil

  def parse_date(date_str) when is_binary(date_str) do
    case DateTime.from_iso8601(date_str) do
      {:ok, datetime, _offset} ->
        datetime

      _ ->
        case Timex.parse(date_str, "{ISO:Extended}") do
          {:ok, datetime} -> datetime
          _ -> nil
        end
    end
  rescue
    _ -> nil
  end

  # magnet and .torrent links are torrents, .nzb links NZBs; anything else is
  # taken as a torrent, as most Cardigann indexers are torrent sites.
  defp detect_download_protocol(url) when is_binary(url) do
    cond do
      String.starts_with?(url, "magnet:") -> :torrent
      String.contains?(url, ".torrent") -> :torrent
      String.contains?(url, "nzb") -> :nzb
      true -> :torrent
    end
  end

  defp detect_download_protocol(_), do: :torrent
end
