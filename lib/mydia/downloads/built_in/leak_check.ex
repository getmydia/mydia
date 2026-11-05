defmodule Mydia.Downloads.BuiltIn.LeakCheck do
  @moduledoc """
  Proves torrent traffic leaves through the VPN: the address the relay sees
  from the torrent group (`torrent-curl`, setgid `mydia-torrent`) must differ
  from the address it sees from Mydia itself.
  """

  def run(opts) do
    url = Keyword.fetch!(opts, :relay_url) <> "/ip"
    torrent_ip = Keyword.get(opts, :torrent_ip_fun, &torrent_ip/1)
    mydia_ip = Keyword.get(opts, :mydia_ip_fun, &mydia_ip/1)

    with {:ok, via_torrent} <- torrent_ip.(url),
         {:ok, via_mydia} <- mydia_ip.(url) do
      if via_torrent == via_mydia, do: {:error, :leak_detected}, else: :ok
    else
      {:error, message} -> {:error, {:leak_check_failed, message}}
    end
  end

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
