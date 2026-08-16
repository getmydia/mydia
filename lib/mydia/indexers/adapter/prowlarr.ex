defmodule Mydia.Indexers.Adapter.Prowlarr do
  @moduledoc """
  Prowlarr indexer adapter.

  Prowlarr is an indexer aggregator that provides a unified interface to
  hundreds of torrent indexers and trackers. This adapter communicates with
  Prowlarr's REST API to search across all configured indexers.

  ## API Documentation

  Prowlarr API: https://prowlarr.com/docs/api/

  ## Authentication

  Authentication is done via X-Api-Key header.

  ## Search Endpoint

  The search endpoint returns results in Torznab/Newznab XML format:
  - `GET /api/v1/search?query={query}&indexerIds={ids}&categories={cats}`

  ## Example Usage

      config = %{
        type: :prowlarr,
        name: "Prowlarr",
        host: "localhost",
        port: 9696,
        api_key: "your-api-key",
        use_ssl: false,
        options: %{
          indexer_ids: [],  # Empty = all enabled indexers. Must be integers (e.g., [1, 2, 3])
          categories: [],    # Empty = all categories
          timeout: 30_000
        }
      }

      {:ok, results} = Prowlarr.search(config, "Ubuntu 22.04")

  ## Important Notes

  - **Indexer IDs**: Prowlarr expects integer indexer IDs (e.g., 1, 2, 3), not UUIDs.
    You can find these IDs in your Prowlarr instance at Settings > Indexers.
    Invalid IDs (UUIDs, strings) will be filtered out with a warning logged.
  """

  @behaviour Mydia.Indexers.Adapter

  alias Mydia.Indexers.{SearchResult, QualityParser}
  alias Mydia.Indexers.Adapter.Error

  require Logger

  # A host that drops SYN packets hangs in TCP connect, a phase receive_timeout
  # does not govern. Slow-but-reachable indexers are unaffected: they connect
  # promptly and then take their time replying, which receive_timeout covers.
  @connect_timeout 10_000

  alias Mydia.Downloads.TorrentHash

  @impl true
  def test_connection(config) do
    url = build_url(config, "/api/v1/system/status")
    headers = build_headers(config)

    case Req.get(url, headers: headers, receive_timeout: 10_000, retry: false) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok,
         %{
           name: "Prowlarr",
           version: body["version"] || "unknown",
           app_name: body["appName"]
         }}

      {:ok, %Req.Response{status: 401}} ->
        {:error, Error.connection_failed("Authentication failed - invalid API key")}

      {:ok, %Req.Response{status: status}} ->
        {:error, Error.connection_failed("HTTP #{status}")}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, Error.connection_failed("Connection failed: #{inspect(reason)}")}

      {:error, reason} ->
        {:error, Error.connection_failed("Request failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def search(config, query, opts \\ []) do
    url = build_search_url(config, query, opts)
    headers = build_headers(config)
    timeout = get_in(config, [:options, :timeout]) || 30_000

    Logger.debug("Prowlarr search: #{url}")

    case Req.get(url,
           headers: headers,
           receive_timeout: timeout,
           connect_options: [timeout: @connect_timeout],
           retry: false
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        parse_search_response(body, config.name)

      {:ok, %Req.Response{status: 401}} ->
        {:error, Error.connection_failed("Authentication failed")}

      {:ok, %Req.Response{status: 429}} ->
        {:error, Error.rate_limited("Rate limit exceeded")}

      {:ok, %Req.Response{status: status, body: body}} ->
        message = extract_error_message(body)
        Logger.warning("Prowlarr search failed (HTTP #{status}): #{message}")
        {:error, Error.search_failed(message)}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, Error.connection_failed("Request timeout")}

      {:error, reason} ->
        {:error, Error.search_failed("Request failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def get_capabilities(_config) do
    # Prowlarr doesn't have a dedicated capabilities endpoint
    # We return a static set of capabilities
    {:ok,
     %{
       searching: %{
         search: %{available: true, supported_params: ["q"]},
         tv_search: %{available: true, supported_params: ["q", "season", "ep", "tvdbid"]},
         movie_search: %{available: true, supported_params: ["q", "imdbid", "tmdbid"]}
       },
       categories: [
         %{id: 2000, name: "Movies"},
         %{id: 2010, name: "Movies/Foreign"},
         %{id: 2020, name: "Movies/Other"},
         %{id: 2030, name: "Movies/SD"},
         %{id: 2040, name: "Movies/HD"},
         %{id: 2045, name: "Movies/UHD"},
         %{id: 2050, name: "Movies/BluRay"},
         %{id: 2060, name: "Movies/3D"},
         %{id: 5000, name: "TV"},
         %{id: 5020, name: "TV/Foreign"},
         %{id: 5030, name: "TV/SD"},
         %{id: 5040, name: "TV/HD"},
         %{id: 5045, name: "TV/UHD"},
         %{id: 5050, name: "TV/Other"},
         %{id: 5060, name: "TV/Sport"},
         %{id: 5070, name: "TV/Anime"},
         %{id: 5080, name: "TV/Documentary"},
         %{id: 8000, name: "Other"},
         %{id: 8010, name: "Other/Misc"}
       ]
     }}
  end

  ## Private Functions

  # Extracts a clean error message from Prowlarr error responses.
  # Prowlarr returns JSON with "message" and "description" keys on errors.
  defp extract_error_message(%{"message" => message}) when is_binary(message) and message != "",
    do: message

  defp extract_error_message(body) when is_map(body), do: inspect(body)
  defp extract_error_message(body) when is_binary(body), do: body
  defp extract_error_message(body), do: inspect(body)

  defp build_url(config, path) do
    scheme = if Map.get(config, :use_ssl, false), do: "https", else: "http"
    base_path = get_in(config, [:options, :base_path]) || ""
    "#{scheme}://#{config.host}:#{config.port}#{base_path}#{path}"
  end

  defp build_headers(config) do
    [
      {"X-Api-Key", config.api_key},
      {"Accept", "application/json"}
    ]
  end

  defp build_search_url(config, query, opts) do
    # Note: We intentionally do NOT use opts[:indexer_ids] here.
    # opts[:indexer_ids] contains mydia config IDs (for filtering which indexer configs to search),
    # while config.options.indexer_ids contains Prowlarr's internal indexer IDs.
    raw_indexer_ids = get_in(config, [:options, :indexer_ids]) || []
    categories = opts[:categories] || get_in(config, [:options, :categories]) || []
    limit = opts[:limit] || 100

    # Prowlarr expects integer indexer IDs, not UUIDs or strings
    # Filter and convert to integers, logging warnings for invalid values
    indexer_ids = validate_and_convert_indexer_ids(raw_indexer_ids, config.name)

    params =
      []
      |> maybe_add_param("query", query)
      |> maybe_add_param("limit", limit)
      |> maybe_add_list_param("indexerIds", indexer_ids)
      |> maybe_add_list_param("categories", categories)

    base_url = build_url(config, "/api/v1/search")
    query_string = URI.encode_query(params)

    "#{base_url}?#{query_string}"
  end

  defp maybe_add_param(params, _key, nil), do: params
  defp maybe_add_param(params, _key, ""), do: params
  defp maybe_add_param(params, key, value), do: [{key, value} | params]

  defp maybe_add_list_param(params, _key, []), do: params

  defp maybe_add_list_param(params, key, list) when is_list(list) do
    # Prowlarr expects repeated query params (e.g., indexerIds=6&indexerIds=17),
    # not comma-separated values (indexerIds=6,17) which returns a 400 error.
    Enum.reduce(list, params, fn value, acc -> [{key, value} | acc] end)
  end

  # Validates and converts indexer IDs to integers.
  # Prowlarr's API expects integer IDs, not UUIDs or arbitrary strings.
  # This function filters out invalid values and logs warnings.
  defp validate_and_convert_indexer_ids([], _config_name), do: []

  defp validate_and_convert_indexer_ids(ids, config_name) when is_list(ids) do
    {valid_ids, invalid_ids} =
      ids
      |> Enum.reduce({[], []}, fn id, {valid, invalid} ->
        case parse_indexer_id(id) do
          {:ok, int_id} -> {[int_id | valid], invalid}
          :error -> {valid, [id | invalid]}
        end
      end)

    # Log warnings for invalid IDs
    if invalid_ids != [] do
      Logger.warning(
        "Prowlarr indexer '#{config_name}' has invalid indexer IDs: #{inspect(invalid_ids)}. " <>
          "Prowlarr expects integer IDs (e.g., 1, 2, 3), not UUIDs or strings. " <>
          "These IDs will be ignored. Check your Prowlarr instance to find the correct indexer IDs."
      )
    end

    Enum.reverse(valid_ids)
  end

  # Attempts to parse an indexer ID to an integer
  defp parse_indexer_id(id) when is_integer(id), do: {:ok, id}

  defp parse_indexer_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int_id, ""} -> {:ok, int_id}
      _ -> :error
    end
  end

  defp parse_indexer_id(_), do: :error

  defp parse_search_response(body, indexer_name) when is_list(body) do
    results =
      body
      |> Enum.map(fn item ->
        parse_result_item(item, indexer_name)
      end)
      |> Enum.reject(&is_nil/1)

    {:ok, results}
  end

  defp parse_search_response(_body, _indexer_name) do
    {:error, Error.parse_error("Invalid response format - expected array")}
  end

  defp parse_result_item(item, indexer_name) do
    try do
      # Extract required fields
      title = item["title"]
      size = item["size"] || 0

      # Extract download URL with preference order:
      # 1. magnetUrl (direct magnet link from indexer)
      # 2. Construct magnet from infoHash if available (bypasses Prowlarr download validation)
      # 3. downloadUrl/link (goes through Prowlarr which can fail on torrent validation)
      download_url =
        item["magnetUrl"] ||
          TorrentHash.build_magnet(item["infoHash"], title) ||
          item["downloadUrl"] ||
          item["link"]

      info_url = item["infoUrl"] || item["guid"]
      indexer = item["indexer"] || indexer_name
      category = item["categoryId"]

      # Parse published date
      published_at =
        case item["publishDate"] do
          nil -> nil
          date_string -> parse_datetime(date_string)
        end

      # Parse quality from title
      quality = QualityParser.parse(title)

      # Extract TMDB, TVDB, and IMDB IDs from indexerFlags or custom fields
      # Prowlarr may return these in different places depending on the indexer
      tmdb_id = extract_tmdb_id(item)
      tvdb_id = extract_tvdb_id(item)
      imdb_id = extract_imdb_id(item)

      # Extract download protocol (torrent vs usenet)
      Logger.debug("Prowlarr item keys: #{inspect(Map.keys(item))}")

      download_protocol =
        case item["downloadProtocol"] || item["protocol"] do
          "torrent" ->
            :torrent

          "usenet" ->
            :nzb

          other ->
            Logger.debug(
              "Protocol field value: #{inspect(other)}, magnetUrl: #{inspect(item["magnetUrl"])}, downloadUrl has .nzb: #{item["downloadUrl"] && String.contains?(item["downloadUrl"], ".nzb")}"
            )

            # Fallback: detect from URL
            cond do
              item["magnetUrl"] -> :torrent
              item["downloadUrl"] && String.contains?(item["downloadUrl"], ".nzb") -> :nzb
              true -> nil
            end
        end

      Logger.debug("Detected protocol: #{inspect(download_protocol)} for #{title}")

      # Protocol-aware seeders/leechers/grabs. Torrents expose seeders+leechers;
      # NZBs expose "grabs" as a popularity metric. Prowlarr returns the same
      # JSON shape for both, so branch on protocol to avoid misrepresenting
      # grabs as seeders.
      {seeders, leechers, nzb_grabs} =
        case download_protocol do
          :nzb -> {nil, nil, parse_int(item["grabs"])}
          :torrent -> {item["seeders"] || 0, item["leechers"] || item["peers"] || 0, nil}
          _ -> {item["seeders"] || 0, item["leechers"] || item["peers"] || 0, nil}
        end

      # For NZB results, Prowlarr's publishDate is the Usenet post date.
      usenet_date = if download_protocol == :nzb, do: published_at, else: nil

      # Some Newznab indexers expose article completion percentage. Prowlarr
      # passes Newznab attrs through transparently. Do NOT fall back to
      # `item["files"]` — that is a file count (e.g. 32 files), not a
      # completion percent, and would silently corrupt the NZB availability
      # score for releases whose indexer omits `completion`.
      nzb_completion =
        if download_protocol == :nzb,
          do: parse_completion(item["completion"]),
          else: nil

      # Stable release identifier used by the release blacklist (#123).
      # Prowlarr exposes a per-result `guid`; fall back to the info URL for
      # legacy responses.
      guid = item["guid"] || item["infoUrl"]

      SearchResult.new(
        title: title,
        size: size,
        seeders: seeders,
        leechers: leechers,
        download_url: download_url,
        info_url: info_url,
        indexer: indexer,
        category: category,
        published_at: published_at,
        quality: quality,
        tmdb_id: tmdb_id,
        tvdb_id: tvdb_id,
        imdb_id: imdb_id,
        download_protocol: download_protocol,
        usenet_date: usenet_date,
        nzb_completion: nzb_completion,
        nzb_grabs: nzb_grabs,
        guid: guid
      )
    rescue
      error ->
        Logger.error("Failed to parse Prowlarr result: #{inspect(error)}")
        Logger.debug("Item: #{inspect(item)}")
        nil
    end
  end

  defp parse_int(nil), do: nil
  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_int(_), do: nil

  # Normalize Newznab completion attribute to a 0.0..1.0 float.
  # Some indexers report percent (0..100), others a ratio (0.0..1.0).
  defp parse_completion(nil), do: nil
  defp parse_completion(value) when is_integer(value), do: parse_completion(value * 1.0)

  defp parse_completion(value) when is_float(value) do
    cond do
      value > 1.0 -> Float.round(value / 100.0, 4)
      value >= 0.0 -> Float.round(value, 4)
      true -> nil
    end
  end

  defp parse_completion(value) when is_binary(value) do
    case Float.parse(value) do
      {n, _} -> parse_completion(n)
      :error -> nil
    end
  end

  defp parse_completion(_), do: nil

  defp parse_datetime(date_string) do
    case DateTime.from_iso8601(date_string) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  # Extract TMDB ID from Prowlarr response
  # Prowlarr can return this in various places depending on indexer
  defp extract_tmdb_id(item) do
    cond do
      # Direct field
      is_integer(item["tmdbId"]) and item["tmdbId"] > 0 ->
        item["tmdbId"]

      # In indexerFlags or attributes
      is_map(item["indexerFlags"]) and is_integer(item["indexerFlags"]["tmdbId"]) ->
        item["indexerFlags"]["tmdbId"]

      # Sometimes in custom fields
      is_list(item["customFields"]) ->
        find_custom_field_id(item["customFields"], "tmdbId")

      true ->
        nil
    end
  end

  # Extract TVDB ID from Prowlarr response
  defp extract_tvdb_id(item) do
    cond do
      is_integer(item["tvdbId"]) and item["tvdbId"] > 0 ->
        item["tvdbId"]

      is_map(item["indexerFlags"]) and is_integer(item["indexerFlags"]["tvdbId"]) ->
        item["indexerFlags"]["tvdbId"]

      is_list(item["customFields"]) ->
        find_custom_field_id(item["customFields"], "tvdbId")

      true ->
        nil
    end
  end

  # Extract IMDB ID from Prowlarr response
  defp extract_imdb_id(item) do
    cond do
      # Direct field
      is_binary(item["imdbId"]) and item["imdbId"] != "" ->
        normalize_imdb_id(item["imdbId"])

      # In indexerFlags or attributes
      is_map(item["indexerFlags"]) and is_binary(item["indexerFlags"]["imdbId"]) ->
        normalize_imdb_id(item["indexerFlags"]["imdbId"])

      # Sometimes in custom fields
      is_list(item["customFields"]) ->
        case find_custom_field_id(item["customFields"], "imdbId") do
          nil -> nil
          id -> normalize_imdb_id(id)
        end

      true ->
        nil
    end
  end

  defp find_custom_field_id(custom_fields, field_name) do
    custom_fields
    |> Enum.find(fn field ->
      is_map(field) and field["name"] == field_name
    end)
    |> case do
      nil -> nil
      field -> field["value"]
    end
  end

  # Normalizes IMDB ID to standard format (tt1234567)
  defp normalize_imdb_id(id_str) when is_binary(id_str) do
    trimmed = String.trim(id_str)

    cond do
      # Already in correct format
      String.starts_with?(trimmed, "tt") -> trimmed
      # Just the numeric part - add tt prefix
      String.match?(trimmed, ~r/^\d+$/) -> "tt#{trimmed}"
      # Invalid format
      true -> trimmed
    end
  end

  defp normalize_imdb_id(_), do: nil

  @doc """
  Lists all indexers configured in Prowlarr.

  Returns a list of indexer maps with id, name, enabled status, and protocol.

  ## Parameters
    - `config` - Configuration map with host, port, api_key, use_ssl

  ## Examples

      iex> list_indexers(%{host: "localhost", port: 9696, api_key: "abc123"})
      {:ok, [%{id: 1, name: "TorrentLeech", enabled: true, protocol: "torrent"}, ...]}
  """
  def list_indexers(config) do
    url = build_url(config, "/api/v1/indexer")
    headers = build_headers(config)

    case Req.get(url, headers: headers, receive_timeout: 10_000) do
      {:ok, %Req.Response{status: 200, body: body}} when is_list(body) ->
        indexers =
          body
          |> Enum.map(fn item ->
            %{
              id: item["id"],
              name: item["name"],
              enabled: item["enable"] || false,
              protocol: item["protocol"] || "torrent"
            }
          end)
          |> Enum.sort_by(& &1.name)

        {:ok, indexers}

      {:ok, %Req.Response{status: 401}} ->
        {:error, Error.connection_failed("Authentication failed - invalid API key")}

      {:ok, %Req.Response{status: status}} ->
        {:error, Error.connection_failed("HTTP #{status}")}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, Error.connection_failed("Request timeout")}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, Error.connection_failed("Connection failed: #{inspect(reason)}")}

      {:error, reason} ->
        {:error, Error.connection_failed("Request failed: #{inspect(reason)}")}
    end
  end
end
