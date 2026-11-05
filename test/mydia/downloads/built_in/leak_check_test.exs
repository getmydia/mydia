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
end
