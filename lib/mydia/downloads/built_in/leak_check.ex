defmodule Mydia.Downloads.BuiltIn.LeakCheck do
  @moduledoc """
  Proves torrent traffic leaves through the VPN: the address the relay sees
  from the torrent group (`torrent-curl`, setgid `mydia-torrent`) must differ
  from the address it sees from Mydia itself.
  """

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
         {:ok, mydia_addr} <- parse_address(via_mydia) do
      if torrent_addr == mydia_addr, do: {:error, :leak_detected}, else: :ok
    else
      {:error, message} -> {:error, {:leak_check_failed, message}}
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

  defp torrent_ip(url) do
    case Mydia.BoundedCommand.run("torrent-curl", ["-fsS", "--max-time", "10", url], 15_000) do
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
