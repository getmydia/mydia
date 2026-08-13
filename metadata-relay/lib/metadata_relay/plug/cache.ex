defmodule MetadataRelay.Plug.Cache do
  @moduledoc """
  Plug middleware for caching HTTP responses.

  This middleware intercepts GET requests, checks if a cached response exists,
  and serves it without making external API calls. If no cache exists, it allows
  the request to proceed and caches the response for future requests.

  ## Usage

  Add to your plug pipeline:

      plug MetadataRelay.Plug.Cache

  The middleware automatically:
  - Caches all successful GET responses (200-299 status)
  - Uses method:path:query_string as cache key
  - Applies appropriate TTL based on endpoint type
  - Skips caching for non-GET requests and errors
  """

  import Plug.Conn
  require Logger

  alias MetadataRelay.Cache

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "GET", request_path: path} = conn, _opts)
      when path in ["/health", "/stats", "/metrics"] do
    # Skip caching for health/stats/metrics endpoints
    conn
  end

  @impl true
  def call(%Plug.Conn{method: "GET", request_path: "/pairing" <> _rest} = conn, _opts) do
    # Skip caching for pairing endpoints (dynamic data, rate limited)
    conn
  end

  @impl true
  def call(%Plug.Conn{method: "GET"} = conn, _opts) do
    cache_key = build_cache_key(conn)

    case Cache.get(cache_key) do
      {:ok, cached_response} ->
        serve_cached_response(conn, cached_response)

      {:error, :not_found} ->
        # Continue with request and cache the response
        conn
        |> register_before_send(&cache_response(&1, cache_key))
    end
  end

  @impl true
  def call(conn, _opts) do
    # Skip caching for non-GET requests
    conn
  end

  ## Private Functions

  defp build_cache_key(conn) do
    method = conn.method
    path = conn.request_path
    query_string = conn.query_string || ""

    Cache.build_key(method, path, query_string)
  end

  defp serve_cached_response(conn, cached_response) do
    MetadataRelay.Metrics.inc("metadata_relay_cache_hits_total")

    case service_from_path(conn.request_path) do
      nil ->
        :ok

      service ->
        MetadataRelay.Metrics.inc("metadata_relay_requests_total", service: service, status: "ok")
    end

    %{status: status, headers: headers, body: body} = cached_response

    conn
    |> merge_resp_headers(headers)
    |> send_resp(status, body)
    |> halt()
  end

  defp service_from_path("/tmdb/" <> _), do: "tmdb"
  defp service_from_path("/tvdb/" <> _), do: "tvdb"
  defp service_from_path("/music/" <> _), do: "music"
  defp service_from_path("/openlibrary/" <> _), do: "openlibrary"
  defp service_from_path("/api/v1/subtitles/" <> _), do: "subdl"
  defp service_from_path(_), do: nil

  defp cache_response(conn, cache_key) do
    # Only cache successful GET responses
    if conn.status in 200..299 do
      MetadataRelay.Metrics.inc("metadata_relay_cache_misses_total")

      cached_response = %{
        status: conn.status,
        headers: filter_headers(conn.resp_headers),
        body: extract_resp_body(conn)
      }

      Cache.put(cache_key, cached_response)
    end

    conn
  end

  defp filter_headers(headers) do
    # Keep only relevant headers for cached responses
    Enum.filter(headers, fn {name, _value} ->
      name in ["content-type", "cache-control", "etag"]
    end)
  end

  defp extract_resp_body(%Plug.Conn{resp_body: body}) when is_binary(body) do
    body
  end

  defp extract_resp_body(%Plug.Conn{resp_body: body}) when is_list(body) do
    IO.iodata_to_binary(body)
  end

  defp extract_resp_body(_conn) do
    ""
  end
end
