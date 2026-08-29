defmodule Mydia.RelayGuardTest do
  # Shares the global escape table with Mydia.RelayGuard.EscapesTest, and with
  # the rest of the suite, which runs with the guard armed from
  # test_helper.exs and relies on Escapes.all() at the end to be a complete
  # account of what was blocked. This module must not call Escapes.reset/0:
  # it used to, in both setup and on_exit, which wiped every escape the rest
  # of the suite had recorded before this module happened to run — the actual
  # cause of the end-of-suite report under-counting real escapes (#530).
  # Isolation instead comes from giving each test its own, never-repeated
  # movie id and filtering `Escapes.all()` down to just the rows it created.
  use ExUnit.Case, async: false

  alias Mydia.RelayGuard
  alias Mydia.RelayGuard.BlockedError
  alias Mydia.RelayGuard.Escapes

  setup do
    Escapes.setup()
    :ok
  end

  # Registers its own on_exit cleanup: a test here deliberately triggers a
  # real guard block as its own assertion, and that row must not linger in
  # the shared table once the test is done, or it would show up in the
  # end-of-suite report as if it were a real, unwarmed application escape.
  defp blocked_url do
    url = "https://relay.mydia.dev/tmdb/movies/#{System.unique_integer([:positive])}"
    on_exit(fn -> Escapes.delete(url) end)
    url
  end

  defp rows_for(urls) when is_list(urls) do
    Enum.filter(Escapes.all(), fn {_key, _count, url, _frames} -> url in urls end)
  end

  defp rows_for(url), do: rows_for([url])

  test "refuses a request to a host that is not this machine" do
    req = Req.new(url: blocked_url(), adapter: RelayGuard)

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
    url = blocked_url()

    req =
      Req.new(
        url: url,
        adapter: RelayGuard,
        retry: :transient,
        max_retries: 3
      )

    assert {:error, %BlockedError{}} = Req.request(req)

    # The escape store counts hits per request, so the count IS the call
    # count. A retried request would reach the adapter 4 times (the attempt
    # plus max_retries: 3) and record 4.
    assert [{_key, 1, ^url, _frames}] = rows_for(url)
  end

  test "records the refused request" do
    url = blocked_url()

    Req.request(Req.new(url: url, adapter: RelayGuard))

    assert [{_key, 1, ^url, _frames}] = rows_for(url)
  end

  test "the error message points at the warming helpers" do
    {:error, error} = Req.request(Req.new(url: blocked_url(), adapter: RelayGuard))

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

  describe "reserved?/1" do
    test "recognises RFC 2606 reserved TLDs on the final label only" do
      assert RelayGuard.reserved?("nonexistent.invalid")
      assert RelayGuard.reserved?("host.test")
      assert RelayGuard.reserved?("site.example")
      refute RelayGuard.reserved?("example.com")
      refute RelayGuard.reserved?("example.net")
      refute RelayGuard.reserved?("example.org")
      refute RelayGuard.reserved?("relay.mydia.dev")
    end

    test "recognises RFC 5737 documentation ranges" do
      assert RelayGuard.reserved?("203.0.113.1")
      assert RelayGuard.reserved?("192.0.2.1")
      assert RelayGuard.reserved?("198.51.100.1")
      refute RelayGuard.reserved?("8.8.8.8")
      refute RelayGuard.reserved?(nil)
    end
  end
end
