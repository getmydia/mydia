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
  attacker-supplied.
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
