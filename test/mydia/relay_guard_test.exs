defmodule Mydia.RelayGuardTest do
  # Shares the global escape table with Mydia.RelayGuard.EscapesTest.
  use ExUnit.Case, async: false

  alias Mydia.RelayGuard
  alias Mydia.RelayGuard.BlockedError
  alias Mydia.RelayGuard.Escapes

  @blocked_url "https://relay.mydia.dev/tmdb/movies/900000123"

  setup do
    Escapes.setup()
    Escapes.reset()
    on_exit(&Escapes.reset/0)
    :ok
  end

  test "refuses a request to a host that is not this machine" do
    req = Req.new(url: @blocked_url, adapter: RelayGuard)

    assert {:error, %BlockedError{}} = Req.request(req)
  end

  test "hands a loopback request to the real adapter" do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "GET", "/ok", fn conn ->
      Plug.Conn.resp(conn, 200, "fine")
    end)

    req = Req.new(url: "http://localhost:#{bypass.port}/ok", adapter: RelayGuard)

    assert {:ok, %Req.Response{status: 200, body: "fine"}} = Req.request(req)
  end

  test "a refused request is not retried" do
    # These are exactly the options Mydia.Metadata.Provider.HTTP.new_request/1
    # sets. A Req.TransportError here would be classified transient and retried
    # with roughly 0.95s + 1.97s + 3.87s of backoff, which is past the 5s
    # render_async budget the detail-page tests use (#530). BlockedError is a
    # plain exception precisely so transient?/1 returns false for it.
    req =
      Req.new(
        url: @blocked_url,
        adapter: RelayGuard,
        retry: :transient,
        max_retries: 3
      )

    assert {:error, %BlockedError{}} = Req.request(req)

    # The escape store counts hits per request, so the count IS the call
    # count. A retried request would reach the adapter 4 times (the attempt
    # plus max_retries: 3) and record 4.
    assert [{_key, 1, @blocked_url, _frames}] =
             Enum.filter(Escapes.all(), fn {_key, _count, url, _frames} ->
               url == @blocked_url
             end)
  end

  test "records the refused request" do
    Req.request(Req.new(url: @blocked_url, adapter: RelayGuard))

    assert Enum.any?(Escapes.all(), fn {_key, _count, url, _frames} ->
             url == @blocked_url
           end)
  end

  test "the error message points at the warming helpers" do
    {:error, error} = Req.request(Req.new(url: @blocked_url, adapter: RelayGuard))

    message = Exception.message(error)

    assert message =~ "relay.mydia.dev"
    assert message =~ "Mydia.MetadataCacheHelpers"
  end

  test "loopback?/1 recognises this machine and nothing else" do
    assert RelayGuard.loopback?("localhost")
    assert RelayGuard.loopback?("127.0.0.1")
    assert RelayGuard.loopback?("::1")
    refute RelayGuard.loopback?("relay.mydia.dev")
    refute RelayGuard.loopback?(nil)
  end
end
