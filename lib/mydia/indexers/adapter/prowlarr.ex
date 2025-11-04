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
          indexer_ids: [],  # Empty = all enabled indexers
          categories: [],    # Empty = all categories
          timeout: 30_000
        }
      }

      {:ok, results} = Prowlarr.search(config, "Ubuntu 22.04")
  """

  @behaviour Mydia.Indexers.Adapter

  alias Mydia.Indexers.{SearchResult, QualityParser}
  alias Mydia.Indexers.Adapter.Error

  require Logger

  @impl true
  def test_connection(config) do
    url = build_url(config, "/api/v1/system/status")
    headers = build_headers(config)

    case Req.get(url, headers: headers, receive_timeout: 10_000) do
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

      {:error, %Mint.TransportError{reason: reason}} ->
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

    case Req.get(url, headers: headers, receive_timeout: timeout) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        parse_search_response(body, config.name)

      {:ok, %Req.Response{status: 401}} ->
        {:error, Error.connection_failed("Authentication failed")}

      {:ok, %Req.Response{status: 429}} ->
        {:error, Error.rate_limited("Rate limit exceeded")}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error("Prowlarr search failed with status #{status}: #{inspect(body)}")
        {:error, Error.search_failed("HTTP #{status}")}

      {:error, %Mint.TransportError{reason: :timeout}} ->
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

  defp build_url(config, path) do
    scheme = if config.use_ssl, do: "https", else: "http"
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
    indexer_ids = opts[:indexer_ids] || get_in(config, [:options, :indexer_ids]) || []
    categories = opts[:categories] || get_in(config, [:options, :categories]) || []
    limit = opts[:limit] || 100

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
    [{key, Enum.join(list, ",")} | params]
  end

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
      seeders = item["seeders"] || 0
      leechers = item["leechers"] || item["peers"] || 0

      # Extract download URL (prefer magnet, fall back to download link)
      download_url =
        item["magnetUrl"] || item["downloadUrl"] || item["link"]

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
        quality: quality
      )
    rescue
      error ->
        Logger.error("Failed to parse Prowlarr result: #{inspect(error)}")
        Logger.debug("Item: #{inspect(item)}")
        nil
    end
  end

  defp parse_datetime(date_string) do
    case DateTime.from_iso8601(date_string) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end
end
