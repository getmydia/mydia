defmodule MetadataRelay.ClientIp do
  @moduledoc """
  Resolves the caller's IP address, for use as a rate-limit identity.

  T-235/T-236/T-250/T-251/T-253/T-254/T-255/T-257: the previous
  implementation trusted `X-Forwarded-For` unconditionally and took its
  *leftmost* entry (the value the client itself supplies), so every IP-keyed
  rate limit in the relay was trivially bypassed by sending a fresh header
  value on every request. `X-Forwarded-For` is now honoured only when
  `conn.remote_ip` (the real TCP peer) is a trusted proxy
  (`MetadataRelay.TrustedProxy`), and when it is, the *rightmost* entry is
  used: each proxy hop appends the peer it received the request from, so
  with a single trusted ingress hop the rightmost entry is the real client
  IP as that ingress observed it, while anything to its left is
  attacker-supplied. That "rightmost entry" reasoning is exactly why this
  is safe against a caller who connects directly to the ingress and forges
  the header: the trusted hop (Traefik) appends *its own observed peer* as
  the last entry when it forwards the request, so the rightmost entry is
  never something the direct caller supplied.

  ## Cloudflare is in front of this, and that header trick doesn't cover it

  Production is `client -> Cloudflare edge -> Traefik -> relay pod`
  (verified 2026-08-23: `relay.mydia.dev` resolves to Cloudflare ranges;
  Traefik's real access logs show its own peer as a Cloudflare edge IP, not
  the end client; Cloudflare's edge sends `CF-Connecting-IP` -- the genuine
  client IP -- rather than `X-Forwarded-For`, which arrived empty on every
  sampled request). `X-Forwarded-For` being absent means every request
  through this path falls through to `remote_ip_string/1`: Traefik's own
  pod address, which is the *same value on every request*. Concretely,
  every distinct install behind Cloudflare currently collapses into one (or
  a small few, if Traefik does add its own hop to an absent header --
  unconfirmed) rate-limit bucket, which is a real fairness/availability bug
  worth fixing.

  `CF-Connecting-IP` is deliberately **not** read here yet, even though it
  would superficially fix that bug, because doing so would reopen exactly
  the T-235/T-236 hole this module exists to close: unlike `X-Forwarded-For`,
  it is a single opaque value that Traefik does not append its own peer to
  -- Traefik has no built-in notion of what this custom header means, so it
  passes through *whatever value it received* unchanged, regardless of
  whether the request came via Cloudflare or hit Traefik's public IP
  directly (not secret -- it's the `external-dns` target in this repo's
  `ingress.yaml`). `MetadataRelay.TrustedProxy.trusted?/1` cannot tell these
  two cases apart either: `conn.remote_ip` is Traefik's in-cluster address
  either way (see its moduledoc). So gating `CF-Connecting-IP` on "peer is
  Traefik" the same way `X-Forwarded-For` is gated would let anyone who
  reaches Traefik's public IP directly pick their own rate-limit identity
  by setting that header themselves -- the identical bypass this whole
  module was written to close, just via a different header name.

  Trusting `CF-Connecting-IP` only becomes safe once something makes "peer
  is Traefik" actually imply "arrived via Cloudflare" -- e.g. restricting
  Traefik's public entrypoint (firewall / `LoadBalancer` source ranges /
  `NetworkPolicy`) to Cloudflare's published IP ranges
  (https://www.cloudflare.com/ips-v4, `/ips-v6`), so that reaching Traefik
  at all is only possible via Cloudflare. That's an infrastructure change
  outside this repo, not something `MetadataRelay.ClientIp` can establish
  on its own from inside a single request.
  """

  import Plug.Conn

  alias MetadataRelay.TrustedProxy

  @spec resolve(Plug.Conn.t()) :: String.t()
  def resolve(conn) do
    if TrustedProxy.trusted?(conn.remote_ip) do
      case get_req_header(conn, "x-forwarded-for") do
        [forwarded | _] -> rightmost_hop(forwarded) || remote_ip_string(conn)
        [] -> remote_ip_string(conn)
      end
    else
      remote_ip_string(conn)
    end
  end

  defp rightmost_hop(forwarded) do
    case forwarded |> String.split(",") |> List.last() |> String.trim() do
      "" -> nil
      ip -> ip
    end
  end

  defp remote_ip_string(conn), do: conn.remote_ip |> :inet.ntoa() |> to_string()
end
