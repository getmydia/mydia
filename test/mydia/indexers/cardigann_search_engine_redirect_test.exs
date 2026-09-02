defmodule Mydia.Indexers.CardigannSearchEngineRedirectTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.CardigannDefinition.Parsed
  alias Mydia.Indexers.CardigannSearchEngine

  @magnet "magnet:?xt=urn:btih:d2e202a5d71ea60b26203f2a9003a1e569382096&dn=Harbour.Lights.S01"

  defp definition(port, opts \\ []) do
    %Parsed{
      id: "redirecttest",
      name: "Redirect Test",
      description: "",
      language: "en-US",
      type: Keyword.get(opts, :type, "public"),
      encoding: "UTF-8",
      links: ["http://localhost:#{port}"],
      capabilities: %{modes: %{}},
      search: %{paths: [%{path: "/search"}], inputs: %{}, rows: %{}, fields: %{}},
      login: nil,
      download: %{selectors: [%{selector: "a.dl", attribute: "href"}]},
      settings: [],
      request_delay: nil,
      follow_redirect: Keyword.get(opts, :follow_redirect, true)
    }
  end

  defp params, do: %{query_params: %{}, headers: [], method: :get, decode_body: false}

  test "a 302 to a magnet resolves to the magnet without a second request" do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "GET", "/dl/1", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", @magnet)
      |> Plug.Conn.resp(302, "")
    end)

    assert {:ok, {:magnet, @magnet}} =
             CardigannSearchEngine.execute_download_request(
               definition(bypass.port),
               "http://localhost:#{bypass.port}/dl/1",
               params(),
               %{},
               %{}
             )
  end

  test "an ordinary http redirect is still followed to the final body" do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "GET", "/dl/2", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "/files/a.torrent")
      |> Plug.Conn.resp(302, "")
    end)

    Bypass.expect_once(bypass, "GET", "/files/a.torrent", fn conn ->
      Plug.Conn.resp(conn, 200, "d8:announce")
    end)

    assert {:ok, {:response, %{status: 200, body: "d8:announce"}}} =
             CardigannSearchEngine.execute_download_request(
               definition(bypass.port),
               "http://localhost:#{bypass.port}/dl/2",
               params(),
               %{},
               %{}
             )
  end

  test "a redirect loop gives up rather than recursing forever" do
    bypass = Bypass.open()

    Bypass.expect(bypass, "GET", "/loop", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "/loop")
      |> Plug.Conn.resp(302, "")
    end)

    assert {:error, %{message: message}} =
             CardigannSearchEngine.execute_download_request(
               definition(bypass.port),
               "http://localhost:#{bypass.port}/loop",
               params(),
               %{},
               %{}
             )

    assert message =~ "Too many redirects"
  end

  test "with follow_redirect: false, a 302 to a magnet still resolves to the magnet" do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "GET", "/dl/4", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", @magnet)
      |> Plug.Conn.resp(302, "")
    end)

    assert {:ok, {:magnet, @magnet}} =
             CardigannSearchEngine.execute_download_request(
               definition(bypass.port, follow_redirect: false),
               "http://localhost:#{bypass.port}/dl/4",
               params(),
               %{},
               %{}
             )
  end

  test "with follow_redirect: false, a 302 to an http url errors without hitting the target" do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "GET", "/dl/5", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "/files/b.torrent")
      |> Plug.Conn.resp(302, "")
    end)

    # No route registered for /files/b.torrent: Bypass fails the test if it
    # receives a request that was never expected or stubbed, so a redirect
    # hop taken here fails the test rather than passing quietly.

    assert {:error, %{message: message}} =
             CardigannSearchEngine.execute_download_request(
               definition(bypass.port, follow_redirect: false),
               "http://localhost:#{bypass.port}/dl/5",
               params(),
               %{},
               %{}
             )

    assert message =~ "Redirected (HTTP 302)"
    assert message =~ "/files/b.torrent"
    assert message =~ "redirect was not followed"
  end

  test "a 3xx with no Location header is an error, not a crash" do
    bypass = Bypass.open()

    Bypass.expect_once(bypass, "GET", "/nowhere", fn conn ->
      Plug.Conn.resp(conn, 302, "")
    end)

    assert {:error, %{message: message}} =
             CardigannSearchEngine.execute_download_request(
               definition(bypass.port),
               "http://localhost:#{bypass.port}/nowhere",
               params(),
               %{},
               %{}
             )

    assert message =~ "no Location header"
  end

  describe "execute_http_request/5 error containment" do
    test "a redirect to an unsupported scheme returns an error instead of raising" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/search", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "ftp://example.invalid/x")
        |> Plug.Conn.resp(302, "")
      end)

      assert {:error, %{message: message}} =
               CardigannSearchEngine.execute_http_request(
                 definition(bypass.port),
                 "http://localhost:#{bypass.port}/search",
                 params(),
                 %{},
                 %{}
               )

      assert message =~ "Request failed" or message =~ "Connection failed"
    end
  end
end
