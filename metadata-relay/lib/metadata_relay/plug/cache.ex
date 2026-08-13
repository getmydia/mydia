defmodule MetadataRelay.Plug.Cache do
  @moduledoc """
  Plug middleware for caching HTTP responses.

  This middleware intercepts cacheable requests, checks if a cached response
  exists, and serves it without making external API calls. If no cache exists,
  it allows the request to proceed and caches the response for future requests.

  ## Usage

  Add to your plug pipeline:

      plug MetadataRelay.Plug.Cache

  The middleware automatically:
  - Caches all successful GET responses (200-299 status)
  - Caches the subtitle search POST, and no other POST (see `@cacheable_post`)
  - Uses method:path:query_string as cache key, where a cached POST's body
    fingerprint stands in for the query string
  - Applies appropriate TTL based on endpoint type
  - Skips caching for every other request and for errors
  """

  import Plug.Conn
  require Logger

  alias MetadataRelay.Cache

  # The only POST the relay caches. Search is the single request that spends the
  # shared SubDL key -- one key, 2000 searches a day, every install behind it --
  # and popular titles repeat heavily between users, so caching it is what makes
  # that allowance viable. Every other POST this service answers either stores
  # something (crash reports, feedback) or mints something new (pairing claims);
  # serving any of those from cache would silently swallow requests. Hence an
  # exact path match rather than a prefix.
  @cacheable_post "/api/v1/subtitles/search"

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
  def call(
        %Plug.Conn{method: "GET", request_path: "/api/v1/subtitles/download/" <> _rest} = conn,
        _opts
      ) do
    # Skip caching for subtitle archive downloads. These hit dl.subdl.com,
    # which is unauthenticated and does not draw on the daily search key
    # quota this cache exists to protect, so caching buys nothing. And with no
    # matching rule in auto_ttl/1 these binary blobs would fall back to the
    # 30-day default and compete with small JSON responses for the same
    # count-capped entry pool.
    conn
  end

  @impl true
  def call(%Plug.Conn{method: "GET"} = conn, _opts) do
    serve_or_cache(conn, build_cache_key(conn))
  end

  @impl true
  def call(%Plug.Conn{method: "POST", request_path: @cacheable_post} = conn, _opts) do
    # The search criteria live in the body, so the body stands in for the query
    # string in the cache key. Without a fingerprint every search would collide
    # on one entry; without a parsed body there is nothing to fingerprint, so
    # that request goes upstream uncached rather than sharing a key.
    case body_fingerprint(conn) do
      {:ok, fingerprint} ->
        serve_or_cache(conn, Cache.build_key(conn.method, conn.request_path, fingerprint))

      :error ->
        conn
    end
  end

  @impl true
  def call(conn, _opts) do
    # Skip caching for every other request
    conn
  end

  ## Private Functions

  defp serve_or_cache(conn, cache_key) do
    case Cache.get(cache_key) do
      {:ok, cached_response} ->
        serve_cached_response(conn, cached_response)

      {:error, :not_found} ->
        # Continue with request and cache the response
        register_before_send(conn, &cache_response(&1, cache_key))
    end
  end

  defp build_cache_key(conn) do
    method = conn.method
    path = conn.request_path
    query_string = conn.query_string || ""

    Cache.build_key(method, path, query_string)
  end

  # Fingerprints the parsed body rather than the raw bytes: two installs asking
  # the same question then share an entry even when their JSON serializers
  # differ in key order or whitespace. Keys are stringified and sorted, list
  # order is preserved because it is meaningful in JSON.
  defp body_fingerprint(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}}), do: :error

  defp body_fingerprint(%Plug.Conn{body_params: params}) when is_map(params) do
    digest =
      params
      |> canonicalize()
      |> :erlang.term_to_binary()

    {:ok, :sha256 |> :crypto.hash(digest) |> Base.encode16(case: :lower)}
  end

  defp body_fingerprint(_conn), do: :error

  defp canonicalize(value) when is_struct(value), do: value

  defp canonicalize(value) when is_map(value) do
    value
    |> Enum.map(fn {key, inner} -> {to_string(key), canonicalize(inner)} end)
    |> Enum.sort()
  end

  defp canonicalize(value) when is_list(value), do: Enum.map(value, &canonicalize/1)

  defp canonicalize(value), do: value

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
    # Keep only relevant headers for cached responses. content-disposition is
    # here because a cached response that drops it changes how the client
    # handles the body: nothing cached carries one today, and this keeps it
    # that way if a file-serving route is ever made cacheable.
    Enum.filter(headers, fn {name, _value} ->
      name in ["content-type", "content-disposition", "cache-control", "etag"]
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
