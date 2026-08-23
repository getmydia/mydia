defmodule MetadataRelay.Plug.ProxyRateLimit do
  @moduledoc """
  Rate-limits the unauthenticated TMDB/TVDB metadata proxy routes.

  T-263: `router.ex`'s plug pipeline had no rate limiter at all ahead of the
  ~30 TMDB/TVDB proxy routes (`check_rate_limit`/`RateLimiter` appeared in
  only 4 places, none of them these routes). `MetadataRelay.Plug.Cache`,
  which does sit ahead of them, is a cache and not a throttle: it is
  trivially defeated per request by appending a throwaway query param (e.g.
  `?_=<random>`), forcing a cache miss and hence a genuine, fully
  credentialed call to the relay's single shared `TMDB_API_KEY`/
  `TVDB_API_KEY` on every request. Two concrete sinks follow from
  sustaining that: exhausting the shared upstream quota/abuse detection
  (every Mydia install depends on this one relay for metadata), and
  churning the cache's fixed entry pool.

  This plug closes that gap with a real per-client-IP request-count limit,
  positioned *after* `MetadataRelay.Plug.Cache` in the pipeline (see
  `router.ex`) so a cache hit -- which spends no upstream credential and
  costs the relay comparatively little -- never counts against it; only a
  genuine cache miss reaches this plug at all, since Plug halts the
  connection on a hit and skips the rest of the pipeline.

  One shared bucket per client IP covers every proxied route together --
  a per-route limit would let an attacker multiply their effective rate by
  spreading requests across the ~30 routes.

  ## Disabled by default, on purpose

  This plug is inert unless `RELAY_PROXY_RATE_LIMIT` is set to a truthy
  value. That is not timidity about a new feature; it is a specific
  consequence of the deployment topology.

  Production sits behind Cloudflare: `client -> Cloudflare edge -> Traefik
  -> relay pod`. `MetadataRelay.ClientIp` can only resolve as far as the
  hop it can actually trust, which behind Cloudflare is a **Cloudflare edge
  address**, not the caller. Cloudflare fronts an enormous number of
  clients from a comparatively small pool of egress addresses, so unrelated
  Mydia installs share a bucket, and a limit low enough to be meaningful
  would 429 innocent installs. The real caller is in `CF-Connecting-IP`,
  but that header cannot be trusted yet: Traefik forwards it unmodified,
  its public entrypoint is not restricted to Cloudflare's ranges, and its
  address is not secret (it is the `external-dns` target checked into
  `infra/kubernetes/apps/metadata-relay/ingress.yaml`). Honouring it today
  would let anyone who reaches the origin directly choose their own
  rate-limit identity -- reintroducing exactly the T-235/T-236 class of bug
  the sibling `ClientIp` fix closes, under a different header name.

  So the ordering is: restrict Traefik's public entrypoint to Cloudflare's
  published ranges first, then teach `ClientIp` to honour
  `CF-Connecting-IP`, and only then turn this on. Shipping it enabled ahead
  of that trades a quota-exhaustion risk for an outage risk across every
  install, which is a bad trade. The code, its tests, and this note ship now
  so that turning it on later is a one-line change rather than a rewrite.
  """

  import Plug.Conn

  alias MetadataRelay.ClientIp
  alias MetadataRelay.RateLimiter

  @behaviour Plug

  # Assumption, stated here for whoever tunes this later: there is no
  # measured production traffic to calibrate against. mydia's own
  # metadata-fetch jobs cap concurrency at 5-10 in-flight requests per
  # install (see `lib/mydia/jobs/library_scanner.ex` and
  # `lib/mydia/metadata/provider/relay.ex` in the main app), so a worst-case
  # burst from one legitimate install -- an initial full-library scan or a
  # "refresh all metadata" pass saturating that concurrency limit
  # back-to-back -- should stay comfortably under 300 requests/minute even
  # at a fast per-request turnaround. That leaves meaningful headroom below
  # this limit for normal usage while still bounding a single attacker's
  # cache-busted flood to a small fraction of an unthrottled rate.
  @limit 300
  @window_ms 60_000

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{request_path: path} = conn, _opts) do
    if enabled?() and proxied_route?(path) do
      enforce(conn)
    else
      conn
    end
  end

  @doc """
  Whether the proxy rate limit is switched on.

  Defaults to `false`. See the "Disabled by default" section of this
  module's documentation for why, and what has to be true before it is
  safe to enable.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:metadata_relay, :proxy_rate_limit_enabled, false) == true
  end

  defp enforce(conn) do
    client_ip = ClientIp.resolve(conn)

    case RateLimiter.check_rate_limit("proxy:#{client_ip}", limit: @limit, window_ms: @window_ms) do
      {:ok, _remaining} ->
        conn

      {:error, :rate_limited} ->
        MetadataRelay.Metrics.inc("metadata_relay_rate_limited_total")

        error_response = %{
          error: "Too many requests",
          message: "Rate limit exceeded. Please try again later."
        }

        retry_after = div(@window_ms, 1000)

        conn
        |> put_resp_header("retry-after", to_string(retry_after))
        |> put_resp_content_type("application/json")
        |> send_resp(429, Jason.encode!(error_response))
        |> halt()
    end
  end

  # `/configuration` is TMDB-backed (see router.ex) but doesn't live under
  # `/tmdb`; everything else in scope does.
  defp proxied_route?("/configuration"), do: true
  defp proxied_route?("/tmdb/" <> _rest), do: true
  defp proxied_route?("/tvdb/" <> _rest), do: true
  defp proxied_route?(_path), do: false
end
