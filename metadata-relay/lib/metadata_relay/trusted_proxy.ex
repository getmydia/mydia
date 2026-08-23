defmodule MetadataRelay.TrustedProxy do
  @moduledoc """
  Decides whether a TCP peer is allowed to set the caller's IP via
  `X-Forwarded-For`.

  T-235/T-236/T-250/T-251/T-253/T-254/T-255/T-257: `get_client_ip/1`
  (`MetadataRelay.ClientIp`) used to honour `X-Forwarded-For` from *any*
  peer, with no check that the peer was actually a proxy the relay trusts.
  Since the header's value is entirely caller-supplied, every IP-keyed rate
  limit in the relay was trivially bypassed by sending a fresh
  `X-Forwarded-For` value on every request. `X-Forwarded-For` is now only
  honoured when `conn.remote_ip` -- the actual TCP peer, which a caller
  cannot spoof over a real connection -- is itself in this trusted set.

  The relay's production deployment sits behind an in-cluster Kubernetes
  ingress (`infra/kubernetes/apps/metadata-relay/ingress.yaml`), reached
  over a private `ClusterIP` address, so the default trusted set is loopback
  plus the RFC 1918 private ranges. This is deliberately not something an
  operator has to configure for the default deployment to work correctly
  (self-hosted operators should never need to fiddle with their
  environment for a security control to function).

  The default is intentionally *broad* rather than scoped to one ingress
  controller's pod CIDR: that CIDR differs by Kubernetes distro and CNI
  (flannel, Calico, Cilium, ...) and isn't something this code can know
  ahead of time, so hardcoding a narrower default risks silently breaking
  trust for the real production deployment (and every other operator's
  differently-configured cluster) with no way to notice short of requests
  failing to get the caller's real IP. That's a materially worse outcome
  than the residual risk being traded off: reaching the relay's `ClusterIP`
  at all already requires being inside the private network, which is a much
  higher bar than the original vulnerability this module closes (any
  internet caller spoofing `X-Forwarded-For`).

  `RELAY_TRUSTED_PROXY_CIDRS`, when set, *replaces* the default set rather
  than extending it -- an operator whose topology needs a narrower trust
  boundary than "all of RFC 1918" (e.g. only the ingress controller's own
  CIDR) can express exactly that, instead of the default always being
  unioned back in regardless of what they configure.

  ## What "trusted" does *not* mean

  This module answers one question only: is `conn.remote_ip` the relay's
  real, non-spoofable TCP peer, i.e. the in-cluster Traefik ingress
  (`infra/kubernetes/apps/metadata-relay/ingress.yaml`)? It says nothing
  about what *Traefik's own* peer was for a given request.

  Production is actually `client -> Cloudflare edge -> Traefik -> relay
  pod` (`relay.mydia.dev` resolves to Cloudflare's anycast ranges, and
  Traefik has no `forwardedHeaders.trustedIPs` configured -- verified
  against live Traefik access logs and its deploy args on 2026-08-23). The
  relay pod's peer is *always* Traefik's in-cluster pod address, whether
  the request genuinely arrived via Cloudflare or reached Traefik's public
  IP directly (that IP is not secret: it's the `external-dns` annotation
  target in this repo's `ingress.yaml`). `trusted?/1` being `true` therefore
  never implies "this request came through Cloudflare" -- only "this
  request came through Traefik", which is true either way. Headers that
  only Cloudflare is supposed to set (`CF-Connecting-IP`, `CF-Ray`, ...)
  are passed through by Traefik unmodified and unvalidated regardless of
  who actually connected to it, so they must not be trusted as client
  identity on the strength of this check alone -- see
  `MetadataRelay.ClientIp` for why that header isn't used yet.
  """

  @default_cidrs [
    # IPv4 loopback
    "127.0.0.0/8",
    # RFC 1918 private ranges
    "10.0.0.0/8",
    "172.16.0.0/12",
    "192.168.0.0/16",
    # IPv6 loopback
    "::1/128"
  ]

  @doc """
  Whether `ip` (an `:inet.ip_address()`, e.g. `conn.remote_ip`) is a trusted
  proxy peer.
  """
  @spec trusted?(:inet.ip_address()) :: boolean()
  def trusted?(ip) do
    Enum.any?(cidrs(), &in_cidr?(ip, &1))
  end

  defp cidrs do
    case configured_cidrs() do
      [] -> @default_cidrs
      configured -> configured
    end
    |> Enum.map(&parse_cidr/1)
    |> Enum.reject(&is_nil/1)
  end

  # Explicit configuration replaces the default set entirely rather than
  # extending it -- an unset or blank env var (including one that is only
  # whitespace, or a comma list of only whitespace/empty segments) falls
  # back to `@default_cidrs`; anything else becomes the complete trusted
  # set, with the default no longer unioned in.
  defp configured_cidrs do
    "RELAY_TRUSTED_PROXY_CIDRS"
    |> System.get_env("")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  @doc false
  # Exposed for tests; not part of the public contract.
  @spec parse_cidr(String.t()) :: {:inet.ip_address(), non_neg_integer()} | nil
  def parse_cidr(cidr_string) do
    with [addr, prefix] <- String.split(cidr_string, "/", parts: 2),
         {:ok, ip} <- :inet.parse_address(String.to_charlist(addr)),
         {prefix_len, ""} <- Integer.parse(prefix),
         true <- prefix_len >= 0 and prefix_len <= max_prefix_len(ip) do
      {ip, prefix_len}
    else
      _ -> nil
    end
  end

  defp max_prefix_len(ip) when tuple_size(ip) == 4, do: 32
  defp max_prefix_len(ip) when tuple_size(ip) == 8, do: 128

  defp in_cidr?(ip, {network_ip, prefix_len})
       when tuple_size(ip) == tuple_size(network_ip) do
    shift = max_prefix_len(ip) - prefix_len
    Bitwise.bsr(ip_to_int(ip), shift) == Bitwise.bsr(ip_to_int(network_ip), shift)
  end

  defp in_cidr?(_ip, _cidr), do: false

  defp ip_to_int({a, b, c, d}) do
    <<int::32>> = <<a::8, b::8, c::8, d::8>>
    int
  end

  defp ip_to_int({a, b, c, d, e, f, g, h}) do
    <<int::128>> = <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>
    int
  end
end
