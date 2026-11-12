defmodule Mydia.Downloads.BuiltIn.LeakCheck do
  @moduledoc """
  Proves torrent traffic leaves through the VPN: the address the relay sees
  from the torrent group (`torrent-curl`, setgid `mydia-torrent`) must differ
  from the address it sees from Mydia itself, and must be the VPN's public
  address when gluetun reports one (`:expected_ip`).
  """

  alias Mydia.Downloads.BuiltIn.Config

  # Fails closed: a value that is not a parseable IP address on either side is
  # a failed check, never a pass, so the engine cannot start on a malformed
  # relay answer.
  def run(opts) do
    url = String.trim_trailing(Keyword.fetch!(opts, :relay_url), "/") <> "/ip"
    torrent_ip = Keyword.get(opts, :torrent_ip_fun, &torrent_ip/1)
    mydia_ip = Keyword.get(opts, :mydia_ip_fun, &mydia_ip/1)

    with {:ok, via_torrent} <- torrent_ip.(url),
         {:ok, via_mydia} <- mydia_ip.(url),
         {:ok, torrent_addr} <- parse_address(via_torrent),
         {:ok, mydia_addr} <- parse_address(via_mydia),
         :ok <- differs(torrent_addr, mydia_addr) do
      matches_vpn(torrent_addr, Keyword.get(opts, :expected_ip))
    else
      {:error, :leak_detected} = leak -> leak
      {:error, message} -> {:error, {:leak_check_failed, message}}
    end
  end

  defp differs(same, same), do: {:error, :leak_detected}
  defp differs(_torrent, _mydia), do: :ok

  defp matches_vpn(_torrent_addr, nil), do: :ok

  defp matches_vpn(torrent_addr, expected_ip) do
    case parse_address(expected_ip) do
      {:ok, ^torrent_addr} ->
        :ok

      _ ->
        {:error, {:leak_check_failed, "torrent traffic is not using the VPN address"}}
    end
  end

  # Compares parsed tuples, so equal addresses written differently (for example
  # IPv6 with and without zero compression) still count as a leak.
  defp parse_address(ip) when is_binary(ip) do
    case :inet.parse_address(:binary.bin_to_list(ip)) do
      {:ok, addr} -> {:ok, addr}
      {:error, _} -> {:error, "invalid address from relay"}
    end
  end

  defp parse_address(_ip), do: {:error, "invalid address from relay"}

  # torrent-curl must not inherit the VPN credentials or Mydia's secrets.
  # `-4` keeps both sides on IPv4: Mydia's own request (Req/Mint) never uses
  # IPv6 by default, and gluetun's split-tunnel marks cover only IPv4, so over
  # IPv6 the two addresses would come from different families and never match
  # the VPN's.
  defp torrent_ip(url) do
    env = Config.child_env_unset(System.get_env())

    case Mydia.BoundedCommand.run("torrent-curl", ["-4", "-fsS", "--max-time", "10", url], 15_000,
           env: env
         ) do
      {:ok, body} -> decode(body)
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp mydia_ip(url) do
    case Req.get(url, retry: false, receive_timeout: 10_000) do
      {:ok, %Req.Response{status: 200, body: %{"ip" => ip}}} -> {:ok, ip}
      {:ok, %Req.Response{status: status}} -> {:error, "relay answered #{status}"}
      {:error, exception} -> {:error, Exception.message(exception)}
    end
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, %{"ip" => ip}} -> {:ok, ip}
      _ -> {:error, "unexpected relay response"}
    end
  end
end
