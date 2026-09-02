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
      follow_redirect: true
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
end
