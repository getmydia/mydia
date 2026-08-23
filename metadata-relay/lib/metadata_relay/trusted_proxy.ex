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
  environment for a security control to function) -- `RELAY_TRUSTED_PROXY_CIDRS`
  exists only as an override for a non-default network topology.
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
    extra =
      "RELAY_TRUSTED_PROXY_CIDRS"
      |> System.get_env("")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)

    (@default_cidrs ++ extra)
    |> Enum.map(&parse_cidr/1)
    |> Enum.reject(&is_nil/1)
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
