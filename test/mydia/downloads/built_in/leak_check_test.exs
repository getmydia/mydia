defmodule Mydia.Downloads.BuiltIn.LeakCheckTest do
  use ExUnit.Case, async: true

  alias Mydia.Downloads.BuiltIn.LeakCheck

  defp run(torrent, mydia) do
    LeakCheck.run(
      relay_url: "https://relay.invalid",
      torrent_ip_fun: fn "https://relay.invalid/ip" -> torrent end,
      mydia_ip_fun: fn "https://relay.invalid/ip" -> mydia end
    )
  end

  test "different addresses pass" do
    assert run({:ok, "203.0.113.9"}, {:ok, "198.51.100.7"}) == :ok
  end

  test "the same address is a leak" do
    assert run({:ok, "198.51.100.7"}, {:ok, "198.51.100.7"}) == {:error, :leak_detected}
  end

  # A request that never got an answer says nothing about where traffic goes,
  # so it is reported apart from a verdict: the gate treats the two differently.
  test "a failed torrent-side request makes the check unreachable" do
    assert run({:unreachable, "timeout"}, {:ok, "198.51.100.7"}) ==
             {:error, {:leak_check_unreachable, "timeout"}}
  end

  test "a failed Mydia-side request makes the check unreachable" do
    assert run({:ok, "203.0.113.9"}, {:unreachable, "nxdomain"}) ==
             {:error, {:leak_check_unreachable, "nxdomain"}}
  end

  test "an answer that is not an address is a failed check, not an unreachable one" do
    assert run({:error, "unexpected relay response"}, {:ok, "198.51.100.7"}) ==
             {:error, {:leak_check_failed, "unexpected relay response"}}
  end

  @invalid {:error, {:leak_check_failed, "invalid address from relay"}}

  test "a nil address on the torrent side fails closed" do
    assert run({:ok, nil}, {:ok, "198.51.100.7"}) == @invalid
  end

  test "a nil address on the Mydia side fails closed" do
    assert run({:ok, "203.0.113.9"}, {:ok, nil}) == @invalid
  end

  test "an empty address on either side fails closed" do
    assert run({:ok, ""}, {:ok, "198.51.100.7"}) == @invalid
    assert run({:ok, "203.0.113.9"}, {:ok, ""}) == @invalid
  end

  test "a non-address string on either side fails closed" do
    assert run({:ok, "garbage"}, {:ok, "198.51.100.7"}) == @invalid
    assert run({:ok, "203.0.113.9"}, {:ok, "garbage"}) == @invalid
  end

  test "invalid UTF-8 on either side fails closed without raising" do
    assert run({:ok, <<0xFF, 0xFE>>}, {:ok, "198.51.100.7"}) == @invalid
    assert run({:ok, "203.0.113.9"}, {:ok, <<0xFF, 0xFE>>}) == @invalid
  end

  test "the same IPv6 address written differently is a leak" do
    assert run({:ok, "2001:db8::1"}, {:ok, "2001:db8:0:0:0:0:0:1"}) == {:error, :leak_detected}
  end

  defp run_expecting(torrent, mydia, expected_ip) do
    LeakCheck.run(
      relay_url: "https://relay.invalid",
      expected_ip: expected_ip,
      torrent_ip_fun: fn _url -> torrent end,
      mydia_ip_fun: fn _url -> mydia end
    )
  end

  test "the torrent side must use the VPN's public address when gluetun reports one" do
    assert run_expecting({:ok, "203.0.113.9"}, {:ok, "198.51.100.7"}, "203.0.113.9") == :ok

    assert run_expecting({:ok, "203.0.113.5"}, {:ok, "198.51.100.7"}, "203.0.113.9") ==
             {:error, {:leak_check_failed, "torrent traffic is not using the VPN address"}}
  end

  # An unreachable result is tolerated by Vpn, so a bad torrent answer must
  # never be masked by Mydia's request failing afterwards.
  test "a wrong torrent address fails the check even when Mydia's side is unreachable" do
    assert run_expecting({:ok, "203.0.113.5"}, {:unreachable, "socket closed"}, "203.0.113.9") ==
             {:error, {:leak_check_failed, "torrent traffic is not using the VPN address"}}
  end

  test "a malformed torrent address fails the check even when Mydia's side is unreachable" do
    assert run_expecting({:ok, "garbage"}, {:unreachable, "socket closed"}, "203.0.113.9") ==
             @invalid
  end

  test "curl diagnostics from retried attempts are not part of the decoded body" do
    output =
      "curl: (28) Connection timed out after 5001 milliseconds\n" <>
        "Warning: Problem : timeout. Will retry in 1 second. 2 retries left.\n" <>
        ~s({"ip":"203.0.113.9"})

    assert LeakCheck.decode_curl_output(output) == {:ok, "203.0.113.9"}
    assert LeakCheck.decode_curl_output(~s({"ip":"203.0.113.9"}\n)) == {:ok, "203.0.113.9"}
    assert LeakCheck.decode_curl_output("") == {:error, "unexpected relay response"}
  end

  test "an unparseable VPN address fails closed" do
    assert run_expecting({:ok, "203.0.113.9"}, {:ok, "198.51.100.7"}, "garbage") ==
             {:error, {:leak_check_failed, "torrent traffic is not using the VPN address"}}
  end

  test "the same address on both sides is still a leak when it matches the VPN address" do
    assert run_expecting({:ok, "203.0.113.9"}, {:ok, "203.0.113.9"}, "203.0.113.9") ==
             {:error, :leak_detected}
  end

  test "a trailing slash on the relay URL is not doubled" do
    # The fns only match the single-slash URL, so a doubled slash raises.
    assert LeakCheck.run(
             relay_url: "https://relay.invalid/",
             torrent_ip_fun: fn "https://relay.invalid/ip" -> {:ok, "203.0.113.9"} end,
             mydia_ip_fun: fn "https://relay.invalid/ip" -> {:ok, "198.51.100.7"} end
           ) == :ok
  end

  describe "the Mydia-side request" do
    defp mydia_side(plug) do
      LeakCheck.run(
        relay_url: "https://relay.invalid",
        torrent_ip_fun: fn _url -> {:ok, "203.0.113.9"} end,
        mydia_req_options: [plug: plug, retry_log_level: false]
      )
    end

    defp counting_plug(responses) do
      counter = :counters.new(1, [])

      plug = fn conn ->
        :counters.add(counter, 1, 1)
        responses.(:counters.get(counter, 1), conn)
      end

      {plug, counter}
    end

    defp ok_ip(conn), do: Req.Test.json(conn, %{"ip" => "198.51.100.7"})

    # Cloudflare closes idle keep-alive connections; a pooled one can be
    # handed out just as it closes. One such request must not fail the check.
    test "a closed connection is retried" do
      {plug, counter} =
        counting_plug(fn
          1, conn -> Req.Test.transport_error(conn, :closed)
          _, conn -> ok_ip(conn)
        end)

      assert mydia_side(plug) == :ok
      assert :counters.get(counter, 1) == 2
    end

    test "a 5xx from the relay is retried" do
      {plug, _counter} =
        counting_plug(fn
          1, conn -> Plug.Conn.send_resp(conn, 502, "bad gateway")
          _, conn -> ok_ip(conn)
        end)

      assert mydia_side(plug) == :ok
    end

    test "a 200 whose body does not decode is a failed check, not retried" do
      {plug, counter} =
        counting_plug(fn _, conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, "{")
        end)

      assert {:error, {:leak_check_failed, _}} = mydia_side(plug)
      assert :counters.get(counter, 1) == 1
    end

    test "a relay that never answers is unreachable after three attempts" do
      {plug, counter} = counting_plug(fn _, conn -> Req.Test.transport_error(conn, :closed) end)

      assert {:error, {:leak_check_unreachable, "socket closed"}} = mydia_side(plug)
      assert :counters.get(counter, 1) == 3
    end
  end

  test "the torrent-side curl retries transient failures within the bounded time" do
    args = LeakCheck.torrent_curl_args("https://relay.invalid/ip")

    assert ["-4", "-fsS" | _] = args
    assert "--retry-all-errors" in args
    assert List.last(args) == "https://relay.invalid/ip"
  end
end
