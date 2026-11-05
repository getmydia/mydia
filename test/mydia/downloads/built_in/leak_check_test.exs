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

  test "a failed torrent-side request fails the check" do
    assert run({:error, "timeout"}, {:ok, "198.51.100.7"}) ==
             {:error, {:leak_check_failed, "timeout"}}
  end

  test "a failed Mydia-side request fails the check" do
    assert run({:ok, "203.0.113.9"}, {:error, "nxdomain"}) ==
             {:error, {:leak_check_failed, "nxdomain"}}
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
end
