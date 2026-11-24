defmodule Mydia.Downloads.BuiltIn.LeakCheck do
  @moduledoc """
  Proves torrent traffic leaves through the VPN: the address the relay sees
  from the torrent group (`torrent-curl`, setgid `mydia-torrent`) must differ
  from the address it sees from Mydia itself, and must be the VPN's public
  address when gluetun reports one (`:expected_ip`).

  A request that never got an answer is `{:leak_check_unreachable, message}`,
  kept apart from `{:leak_check_failed, message}` (an answer that failed the
  check): an unanswered request says nothing about where traffic goes, and
  `Vpn` tolerates a few of them on a reverify. Both requests retry transient
  failures first, since the check runs every minute over the internet.
  """

  alias Mydia.Downloads.BuiltIn.Config

  @retries 2
  @retry_delay_ms 250

  # Fails closed: a value that is not a parseable IP address on either side is
  # a failed check, never a pass, so the engine cannot start on a malformed
  # relay answer.
  def run(opts) do
    url = String.trim_trailing(Keyword.fetch!(opts, :relay_url), "/") <> "/ip"
    torrent_ip = Keyword.get(opts, :torrent_ip_fun, &torrent_ip/1)
    req_options = Keyword.get(opts, :mydia_req_options, [])
    mydia_ip = Keyword.get(opts, :mydia_ip_fun, &mydia_ip(&1, req_options))

    with {:ok, via_torrent} <- torrent_ip.(url),
         {:ok, via_mydia} <- mydia_ip.(url),
         {:ok, torrent_addr} <- parse_address(via_torrent),
         {:ok, mydia_addr} <- parse_address(via_mydia),
         :ok <- differs(torrent_addr, mydia_addr) do
      matches_vpn(torrent_addr, Keyword.get(opts, :expected_ip))
    else
      {:error, :leak_detected} = leak -> leak
      {:unreachable, message} -> {:error, {:leak_check_unreachable, message}}
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

    # Bounds the whole curl run: three attempts of at most 10s each, plus the
    # retry delays, plus slack for process start-up.
    case Mydia.BoundedCommand.run("torrent-curl", torrent_curl_args(url), 35_000, env: env) do
      {:ok, body} -> decode(body)
      {:error, reason} -> {:unreachable, inspect(reason)}
    end
  end

  @doc false
  # Connects through the tunnel occasionally stall while lost SYNs are
  # retransmitted, so each attempt gets a short connect timeout and curl
  # retries any failure. `--retry-max-time` stops it starting a new attempt
  # after 20s.
  def torrent_curl_args(url) do
    ["-4", "-fsS", "--connect-timeout", "5", "--max-time", "10"] ++
      ["--retry", "#{@retries}", "--retry-delay", "1", "--retry-max-time", "20"] ++
      ["--retry-all-errors", url]
  end

  # A pooled keep-alive connection can be closed by the relay's CDN just as it
  # is reused, which surfaces as a `socket closed` transport error. The request
  # is an idempotent GET, so any transport error or 5xx is retried.
  defp mydia_ip(url, req_options) do
    options =
      Keyword.merge(
        [
          retry: &retry_mydia_request?/2,
          retry_delay: fn _attempt -> @retry_delay_ms end,
          max_retries: @retries,
          receive_timeout: 5_000,
          connect_options: [timeout: 5_000]
        ],
        req_options
      )

    case Req.get(url, options) do
      {:ok, %Req.Response{status: 200, body: %{"ip" => ip}}} -> {:ok, ip}
      {:ok, %Req.Response{status: 200}} -> {:error, "unexpected relay response"}
      {:ok, %Req.Response{status: status}} -> {:unreachable, "relay answered #{status}"}
      {:error, exception} -> {:unreachable, Exception.message(exception)}
    end
  end

  defp retry_mydia_request?(_request, %Req.TransportError{}), do: true
  defp retry_mydia_request?(_request, %Req.Response{status: status}) when status >= 500, do: true
  defp retry_mydia_request?(_request, _response_or_exception), do: false

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, %{"ip" => ip}} -> {:ok, ip}
      _ -> {:error, "unexpected relay response"}
    end
  end
end
