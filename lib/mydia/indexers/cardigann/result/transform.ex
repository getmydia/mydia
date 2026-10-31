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
  alias Mydia.Indexers.Structs.{SearchResultMetadata, TrackerTerms}

  # Cardigann field names match the Torznab attribute names, minimum seed time
  # in seconds included. Privacy comes from the definition's type, added by
  # AdapterSupport.put_definition_privacy/2.
  @term_fields ~w(downloadvolumefactor uploadvolumefactor minimumratio minimumseedtime)

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
        category: category(row, ctx),
        published_at: parse_date(get_field(row, "date")),
        quality: QualityParser.parse(title),
        tmdb_id: parse_optional_integer(get_field(row, "tmdbid")),
        imdb_id: get_field(row, "imdbid"),
        download_protocol: detect_download_protocol(resolved_download_url),
        guid: release_guid(row, resolved_download_url, ctx),
        metadata: source_metadata(row, resolved_download_url, ctx),
        terms: TrackerTerms.from_torznab(Map.take(row, @term_fields))
      }
    else
      _ -> nil
    end
  end

  # The infohash wins the download URL (get_download_or_magnet/2); the link it
  # replaced is kept for the parity comparator, which holds it against
  # Prowlarr's download URL.
  defp source_metadata(row, "magnet:" <> _, ctx) do
    case get_required_field(row, "download") do
      {:ok, "magnet:" <> _} ->
        nil

      {:ok, url} ->
        SearchResultMetadata.new(source_download_url: LinkResolver.resolve(url, ctx.base_url))

      {:error, _} ->
        nil
    end
  end

  defp source_metadata(_row, _download_url, _ctx), do: nil

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

  # `category` first, then `categorydesc`: Prowlarr unions them in field order
  # and the first category is the one a release reports. An unmapped
  # non-numeric category parses to 0, which is no category at all, so it must
  # not shadow `categorydesc`; when that maps nothing either, the 0 stands.
  defp category(row, ctx) do
    case map_category(get_field(row, "category"), ctx.category_mappings) do
      category when is_integer(category) and category > 0 ->
        category

      unmapped ->
        CategoryMapping.map_site_category_desc_to_torznab(
          get_field(row, "categorydesc"),
          ctx.category_mappings
        ) || unmapped
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

  @spec get_field(map(), String.t(), String.t() | nil) :: String.t() | nil
  defp get_field(row, field, default \\ nil), do: Map.get(row, field) || default

  @spec parse_size_with_title_fallback(String.t() | nil, String.t()) :: non_neg_integer()
  def parse_size_with_title_fallback(raw_size, title) do
    case parse_size(raw_size) do
      0 -> title_size(title)
      size -> size
    end
  end

  # The title fallback is mydia's, not Prowlarr's, so it first has to find a
  # "number unit" pair inside free text before handing it to the shared parser.
  @title_size_pattern ~r/([\d,]+(?:\.\d+)?)\s*(tib|tb|gib|gb|mib|mb|kib|kb)/i

  defp title_size(title) when is_binary(title) do
    case Regex.run(@title_size_pattern, title) do
      [match | _] -> parse_size(match)
      nil -> 0
    end
  end

  defp title_size(_), do: 0

  @doc """
  Reads a size the way Prowlarr's `ParseUtil.GetBytes(string)` does
  (`src/NzbDrone.Core/Parser/ParseUtil.cs`): the unit is every letter in the
  value and the number is every digit, dot and comma, normalized by
  `NormalizeNumber`. Commas count as decimal points and only the last dot
  survives, so "1,5 GB" is 1.5 GiB, "1.234,5 MB" is 1234.5 MiB and
  "1,017.6 MB" is 1017.6 MiB, while "2,048 KB" is 2.048 KiB.
  """
  @spec parse_size(String.t() | nil) :: non_neg_integer()
  def parse_size(nil), do: 0

  def parse_size(size_str) when is_binary(size_str) do
    case coerce_double(size_str) do
      {:ok, value} -> bytes(String.replace(size_str, ~r/\P{L}/u, ""), value)
      # Prowlarr throws here and drops the row; returning zero lets the title
      # fallback supply the size instead of failing the result.
      :error -> 0
    end
  rescue
    # A number past the double range. .NET 8 parses it to Infinity and casts
    # that to a meaningless long, keeping the row; BEAM floats raise instead
    # (ArgumentError in String.to_float, ArithmeticError in arithmetic), which
    # would fail the whole response. Zero keeps the row and lets the title
    # fallback supply the size.
    _ in [ArgumentError, ArithmeticError] -> 0
  end

  # ParseUtil.GetBytes(string unit, double value). The "i" is dropped before
  # lowercasing, as Prowlarr does, so "MiB" reads as "mb".
  defp bytes(unit, value) do
    unit = unit |> String.replace("i", "") |> String.downcase()

    cond do
      String.contains?(unit, "kb") -> scale(value, 1)
      String.contains?(unit, "mb") -> scale(value, 2)
      String.contains?(unit, "gb") -> scale(value, 3)
      String.contains?(unit, "tb") -> scale(value, 4)
      true -> trunc(value)
    end
  end

  # BytesFromTB/GB/MB/KB multiply by 1024 one step at a time in doubles and
  # truncate once at the end, so the same order is kept here.
  defp scale(value, 0), do: trunc(value)
  defp scale(value, steps), do: scale(value * 1024.0, steps - 1)

  # ParseUtil.CoerceDouble: double.Parse(NormalizeNumber(s)).
  defp coerce_double(str) do
    case String.split(normalize_number(str), ".") do
      [int] -> {:ok, String.to_integer(int) * 1.0}
      ["", ""] -> :error
      [int, frac] -> {:ok, String.to_float(zero_if_empty(int) <> "." <> zero_if_empty(frac))}
    end
  end

  defp zero_if_empty(""), do: "0"
  defp zero_if_empty(digits), do: digits

  # ParseUtil.NormalizeNumber(s, isInt: false). Keep digits, dots and commas;
  # an empty value is "0"; every comma becomes a dot; when more than one dot
  # remains, all but the last are thousands separators and are removed.
  # Prowlarr also replaces "-" with "0", which cannot match after the filter.
  defp normalize_number(str) do
    case String.replace(str, ~r/[^0-9.,]/, "") do
      "" ->
        "0"

      digits ->
        value = String.replace(digits, ",", ".")

        case String.split(value, ".") do
          [_] -> value
          [_, _] -> value
          parts -> Enum.join(Enum.drop(parts, -1)) <> "." <> List.last(parts)
        end
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
