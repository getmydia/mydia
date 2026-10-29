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
        guid: release_guid(row, resolved_download_url, ctx)
      }
    else
      _ -> nil
    end
  end

  # Prowlarr's CleanupReleases fills an unset guid from the release's download
  # URL, then a torrent's magnet, then its details URL. A row without a
  # download field or an infohash never gets here, so its details URL cannot
  # supply the guid; the download field wins even when the infohash supplies
  # the download URL, as on YTS.
  defp release_guid(row, download_url, ctx) do
    case get_required_field(row, "download") do
      {:ok, url} -> LinkResolver.resolve(url, ctx.base_url)
      {:error, _} -> download_url
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
      0 -> size_in_bytes(title) || 0
      size -> size
    end
  end

  # One table, longest spelling first, so a value is read in the unit it names.
  @size_units [
    {"tib", 1024 * 1024 * 1024 * 1024},
    {"tb", 1024 * 1024 * 1024 * 1024},
    {"gib", 1024 * 1024 * 1024},
    {"gb", 1024 * 1024 * 1024},
    {"mib", 1024 * 1024},
    {"mb", 1024 * 1024},
    {"kib", 1024},
    {"kb", 1024}
  ]
  @size_pattern Regex.compile!(
                  "([\\d,]+(?:\\.[\\d]+)?)\\s*(#{Enum.map_join(@size_units, "|", &elem(&1, 0))})",
                  "i"
                )

  @spec parse_size(String.t() | nil) :: non_neg_integer()
  def parse_size(nil), do: 0
  def parse_size(""), do: 0

  def parse_size(size_str) when is_binary(size_str) do
    size_in_bytes(size_str) || parse_integer(size_str)
  end

  # A number, with or without thousands separators, followed by a unit.
  defp size_in_bytes(str) when is_binary(str) do
    case Regex.run(@size_pattern, str) do
      [_, number, unit] ->
        {_, multiplier} = List.keyfind(@size_units, String.downcase(unit), 0)

        case Float.parse(String.replace(number, ",", "")) do
          {value, _rest} -> trunc(value * multiplier)
          # A unit with no number, as in ", MB". Falling through lets the
          # title fallback supply the size instead of failing the whole search.
          :error -> nil
        end

      nil ->
        nil
    end
  end

  defp size_in_bytes(_), do: nil

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
    date_str = String.trim(date_str)

    cond do
      date_str == "" -> nil
      String.match?(date_str, ~r/^\d+$/) -> parse_unix(date_str)
      String.contains?(String.downcase(date_str), "now") -> DateTime.utc_now()
      true -> parse_datetime(date_str)
    end
  rescue
    _ -> nil
  end

  # Prowlarr's DateTimeUtil.FromUnknown treats an all-digit value as Unix
  # seconds and any value naming "now" as the current time, before trying its
  # date layouts.
  defp parse_unix(seconds_str) do
    case Integer.parse(seconds_str) do
      {seconds, ""} ->
        case DateTime.from_unix(seconds) do
          {:ok, datetime} -> datetime
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp parse_datetime(date_str) do
    case DateTime.from_iso8601(date_str) do
      {:ok, datetime, _offset} -> datetime
      _ -> parse_timex(date_str)
    end
  end

  defp parse_timex(date_str) do
    Enum.find_value(["{ISO:Extended}", "{RFC1123}"], fn format ->
      case Timex.parse(date_str, format) do
        {:ok, datetime} -> datetime
        _ -> nil
      end
    end)
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
