defmodule Mydia.Indexers.Adapter.Jackett do
  @moduledoc """
  Jackett indexer adapter.

  Jackett is a popular indexer aggregator that provides access to many torrent
  trackers through a unified Torznab interface. This adapter communicates with
  Jackett's Torznab API to search across all configured indexers.

  ## API Documentation

  Jackett API: https://github.com/Jackett/Jackett
  Torznab Spec: https://torznab.github.io/spec-1.3-draft/

  ## Authentication

  Authentication is done via apikey query parameter.

  ## Search Endpoint

  The search endpoint returns results in Torznab XML format:
  - `GET /api/v2.0/indexers/all/results/torznab/api?apikey={key}&t=search&q={query}`

  The special "all" indexer queries all configured indexers and returns combined results.

  ## Example Usage

      config = %{
        type: :jackett,
        name: "Jackett",
        host: "localhost",
        port: 9117,
        api_key: "your-api-key",
        use_ssl: false,
        options: %{
          timeout: 30_000
        }
      }

      {:ok, results} = Jackett.search(config, "Ubuntu 22.04")
  """

  @behaviour Mydia.Indexers.Adapter

  alias Mydia.Indexers.{SearchResult, QualityParser}
  alias Mydia.Indexers.Adapter.Error

  import SweetXml

  require Logger

  @connect_timeout 10_000

  # Torznab XML namespace
  @torznab_ns "http://torznab.com/schemas/2015/feed"

  @impl true
  def test_connection(config) do
    # Test connection by requesting capabilities
    url = build_url(config, "/api/v2.0/indexers/all/results/torznab/api")
    params = [{"apikey", config.api_key}, {"t", "caps"}]
    query_string = URI.encode_query(params)
    full_url = "#{url}?#{query_string}"

    case Req.get(full_url, receive_timeout: 10_000, retry: false) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        parse_caps_response(body)

      {:ok, %Req.Response{status: 403}} ->
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
    timeout = get_in(config, [:options, :timeout]) || 30_000

    Logger.debug("Jackett search: #{url}")

    case Req.get(url,
           receive_timeout: timeout,
           connect_options: [timeout: @connect_timeout],
           retry: false
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        parse_search_response(body, config.name)

      {:ok, %Req.Response{status: 403}} ->
        {:error, Error.connection_failed("Authentication failed")}

      {:ok, %Req.Response{status: 429}} ->
        {:error, Error.rate_limited("Rate limit exceeded")}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error("Jackett search failed with status #{status}: #{inspect(body)}")
        {:error, Error.search_failed("HTTP #{status}")}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, Error.connection_failed("Request timeout")}

      {:error, reason} ->
        {:error, Error.search_failed("Request failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def get_capabilities(config) do
    # Use the test_connection which already fetches capabilities
    case test_connection(config) do
      {:ok, caps} when is_map(caps) and not is_map_key(caps, :name) ->
        # If caps doesn't have :name, it's already the capabilities map
        {:ok, caps}

      {:ok, %{name: _}} ->
        # If it has :name, we need to fetch capabilities separately
        fetch_capabilities(config)

      {:error, reason} ->
        {:error, reason}
    end
  end

  ## Private Functions

  defp build_url(config, path) do
    scheme = if Map.get(config, :use_ssl, false), do: "https", else: "http"
    base_path = get_in(config, [:options, :base_path]) || ""
    "#{scheme}://#{config.host}:#{config.port}#{base_path}#{path}"
  end

  defp build_search_url(config, query, opts) do
    categories = opts[:categories] || get_in(config, [:options, :categories]) || []
    limit = opts[:limit] || 100

    params =
      [
        {"apikey", config.api_key},
        {"t", "search"},
        {"q", query}
      ]
      |> maybe_add_param("limit", limit)
      |> maybe_add_list_param("cat", categories)

    base_url = build_url(config, "/api/v2.0/indexers/all/results/torznab/api")
    query_string = URI.encode_query(params)

    "#{base_url}?#{query_string}"
  end

  defp maybe_add_param(params, _key, nil), do: params
  defp maybe_add_param(params, _key, ""), do: params
  defp maybe_add_param(params, key, value), do: params ++ [{key, value}]

  defp maybe_add_list_param(params, _key, []), do: params

  defp maybe_add_list_param(params, key, list) when is_list(list) do
    params ++ [{key, Enum.join(list, ",")}]
  end

  defp parse_caps_response(body) when is_binary(body) do
    try do
      # Parse the XML to extract server name/version if available
      doc = SweetXml.parse(body)

      # Try to get server info from caps
      server = xpath(doc, ~x"//caps/@server"s)
      version = xpath(doc, ~x"//caps/@version"s)

      {:ok,
       %{
         name: if(server != "", do: server, else: "Jackett"),
         version: if(version != "", do: version, else: "unknown"),
         app_name: "Jackett"
       }}
    rescue
      error ->
        Logger.error("Failed to parse Jackett caps response: #{inspect(error)}")
        # Still return success but with minimal info
        {:ok, %{name: "Jackett", version: "unknown", app_name: "Jackett"}}
    end
  end

  defp fetch_capabilities(config) do
    url = build_url(config, "/api/v2.0/indexers/all/results/torznab/api")
    params = [{"apikey", config.api_key}, {"t", "caps"}]
    query_string = URI.encode_query(params)
    full_url = "#{url}?#{query_string}"

    case Req.get(full_url, receive_timeout: 10_000) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        parse_capabilities_xml(body)

      {:ok, %Req.Response{status: status}} ->
        {:error, Error.connection_failed("HTTP #{status}")}

      {:error, reason} ->
        {:error, Error.connection_failed("Request failed: #{inspect(reason)}")}
    end
  end

  defp parse_capabilities_xml(body) when is_binary(body) do
    try do
      doc = SweetXml.parse(body)

      # Parse categories
      categories =
        doc
        |> xpath(
          ~x"//categories/category"l,
          id: ~x"./@id"s,
          name: ~x"./@name"s
        )
        |> Enum.map(fn cat ->
          %{
            id: String.to_integer(cat.id),
            name: cat.name
          }
        end)

      {:ok,
       %{
         searching: %{
           search: %{available: true, supported_params: ["q"]},
           tv_search: %{available: true, supported_params: ["q", "season", "ep", "tvdbid"]},
           movie_search: %{available: true, supported_params: ["q", "imdbid"]}
         },
         categories: categories
       }}
    rescue
      error ->
        Logger.error("Failed to parse Jackett capabilities: #{inspect(error)}")
        {:error, Error.parse_error("Failed to parse capabilities XML")}
    end
  end

  defp parse_search_response(body, indexer_name) when is_binary(body) do
    try do
      doc = SweetXml.parse(body)

      results =
        doc
        |> xpath(
          ~x"//channel/item"l,
          title: ~x"./title/text()"s,
          link: ~x"./link/text()"s,
          guid: ~x"./guid/text()"s,
          comments: ~x"./comments/text()"s,
          pub_date: ~x"./pubDate/text()"s,
          size: ~x"./enclosure/@length"s,
          enclosure_url: ~x"./enclosure/@url"s,
          # Torznab attributes
          seeders:
            ~x"./torznab:attr[@name='seeders']/@value"s |> add_namespace("torznab", @torznab_ns),
          leechers:
            ~x"./torznab:attr[@name='peers']/@value"s |> add_namespace("torznab", @torznab_ns),
          magnet:
            ~x"./torznab:attr[@name='magneturl']/@value"s |> add_namespace("torznab", @torznab_ns),
          download_url:
            ~x"./torznab:attr[@name='downloadurl']/@value"s
            |> add_namespace("torznab", @torznab_ns),
          category:
            ~x"./torznab:attr[@name='category']/@value"s |> add_namespace("torznab", @torznab_ns),
          tmdb_id:
            ~x"./torznab:attr[@name='tmdbid']/@value"s |> add_namespace("torznab", @torznab_ns),
          tvdb_id:
            ~x"./torznab:attr[@name='tvdbid']/@value"s |> add_namespace("torznab", @torznab_ns),
          imdb_id:
            ~x"./torznab:attr[@name='imdbid']/@value"s |> add_namespace("torznab", @torznab_ns),
          tracker: ~x"./jackettindexer/text()"s
        )
        |> Enum.map(fn item ->
          parse_result_item(item, indexer_name)
        end)
        |> Enum.reject(&is_nil/1)

      {:ok, results}
    rescue
      error ->
        Logger.error("Failed to parse Jackett search response: #{inspect(error)}")
        Logger.debug("Body: #{inspect(body)}")
        {:error, Error.parse_error("Failed to parse search results XML")}
    end
  end

  defp parse_result_item(item, indexer_name) do
    try do
      # Extract required fields
      title = item.title

      # Size from enclosure or torznab attr
      size =
        case item.size do
          "" -> 0
          size_str -> String.to_integer(size_str)
        end

      # Seeders and leechers
      seeders =
        case item.seeders do
          "" -> 0
          seeders_str -> String.to_integer(seeders_str)
        end

      leechers =
        case item.leechers do
          "" -> 0
          leechers_str -> String.to_integer(leechers_str)
        end

      # Download URL - prefer magnet, fall back to download_url, then enclosure, then link
      download_url =
        cond do
          item.magnet != "" -> item.magnet
          item.download_url != "" -> item.download_url
          item.enclosure_url != "" -> item.enclosure_url
          item.link != "" -> item.link
          true -> ""
        end

      # Info URL - prefer comments, fall back to guid
      info_url =
        cond do
          item.comments != "" -> item.comments
          item.guid != "" -> item.guid
          true -> nil
        end

      # Indexer - prefer tracker name, fall back to configured name
      indexer =
        if item.tracker != "", do: item.tracker, else: indexer_name

      # Category
      category =
        case item.category do
          "" -> nil
          cat_str -> String.to_integer(cat_str)
        end

      # Parse published date
      published_at =
        case item.pub_date do
          "" -> nil
          date_string -> parse_datetime(date_string)
        end

      # Parse quality from title
      quality = QualityParser.parse(title)

      # Parse TMDB ID
      tmdb_id =
        case item.tmdb_id do
          "" -> nil
          id_str -> String.to_integer(id_str)
        end

      # Parse TVDB ID
      tvdb_id =
        case item.tvdb_id do
          "" -> nil
          id_str -> String.to_integer(id_str)
        end

      # Parse IMDB ID (format: tt1234567 or just 1234567)
      imdb_id =
        case item.imdb_id do
          "" -> nil
          id_str -> normalize_imdb_id(id_str)
        end

      # Stable release identifier used by the release blacklist (#123).
      guid =
        cond do
          item.guid != "" -> item.guid
          item.comments != "" -> item.comments
          true -> nil
        end

      # Skip results without download URL
      if download_url == "" do
        Logger.debug("Skipping result without download URL: #{title}")
        nil
      else
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
          guid: guid
        )
      end
    rescue
      error ->
        Logger.error("Failed to parse Jackett result item: #{inspect(error)}")
        Logger.debug("Item: #{inspect(item)}")
        nil
    end
  end

  defp parse_datetime(date_string) do
    # Torznab uses RFC 2822 date format (like RSS)
    # Example: "Mon, 02 Jan 2006 15:04:05 -0700"
    case Timex.parse(date_string, "{RFC1123}") do
      {:ok, datetime} -> datetime
      {:error, _reason} -> nil
    end
  end

  # Normalizes IMDB ID to standard format (tt1234567)
  defp normalize_imdb_id(id_str) do
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
end
