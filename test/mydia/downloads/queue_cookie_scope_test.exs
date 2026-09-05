defmodule Mydia.Downloads.QueueCookieScopeTest do
  @moduledoc """
  Regression for #607: the cookie-scoping rules #601/#606 established for the
  Cardigann search and auth paths (`Mydia.Indexers.Cardigann.CredentialScope`)
  never reached `Mydia.Downloads.Queue`'s own download path
  (`download_torrent_file/2`). A tracker's session cookie followed
  `download_url` to any host at all, with no origin check, and survived a
  redirect off that host.
  """
  use Mydia.DataCase, async: false

  alias Mydia.Downloads.Queue
  alias Mydia.Indexers.CardigannAuth
  alias Mydia.Indexers.CardigannDefinition
  alias Mydia.Indexers.SearchResult
  alias Mydia.Repo

  @yaml """
  ---
  id: cookiescopetest
  name: CookieScopeTest
  description: "Test indexer for the #607 cookie scope regression"
  language: en-US
  type: private
  encoding: UTF-8
  links:
    - http://localhost:PORT/
  caps:
    modes:
      search: [q]
  settings: []
  search:
    paths:
      - path: "search"
    rows:
      selector: tr
    fields:
      title:
        text: x
      size:
        text: "0"
      seeders:
        text: "0"
  """

  defp store_definition!(port) do
    yaml = String.replace(@yaml, "PORT", to_string(port))

    %CardigannDefinition{}
    |> CardigannDefinition.changeset(%{
      indexer_id: "cookiescopetest",
      name: "CookieScopeTest",
      type: "private",
      links: %{"main" => "http://localhost:#{port}/"},
      capabilities: %{},
      definition: yaml,
      schema_version: "1",
      enabled: true
    })
    |> Repo.insert!()
  end

  defp search_result(download_url) do
    %SearchResult{
      title: "Some.Release.1080p",
      indexer: "CookieScopeTest",
      download_url: download_url,
      size: 1_000,
      seeders: 1,
      leechers: 1,
      download_protocol: :torrent
    }
  end

  test "a download host outside the indexer's own origins never receives the session cookie" do
    home = Bypass.open()
    foreign = Bypass.open()
    test_pid = self()

    definition = store_definition!(home.port)
    {:ok, _session} = CardigannAuth.store_session(definition.id, ["session=topsecret"])

    Bypass.stub(foreign, "HEAD", "/download", fn conn ->
      Plug.Conn.resp(conn, 200, "")
    end)

    Bypass.stub(foreign, "GET", "/download", fn conn ->
      send(test_pid, {:cookie_header, Plug.Conn.get_req_header(conn, "cookie")})
      Plug.Conn.resp(conn, 200, "d8:announce")
    end)

    Queue.select_and_add_to_client(search_result("http://localhost:#{foreign.port}/download"), [])

    assert_receive {:cookie_header, cookie_header}, 2_000
    assert cookie_header == []
  end

  test "a session cookie does not survive a redirect off the indexer's own host" do
    home = Bypass.open()
    foreign = Bypass.open()
    test_pid = self()

    definition = store_definition!(home.port)
    {:ok, _session} = CardigannAuth.store_session(definition.id, ["session=topsecret"])

    Bypass.expect_once(home, "HEAD", "/download", fn conn ->
      send(test_pid, {:home_cookie_header, Plug.Conn.get_req_header(conn, "cookie")})

      conn
      |> Plug.Conn.put_resp_header("location", "http://localhost:#{foreign.port}/download")
      |> Plug.Conn.resp(302, "")
    end)

    Bypass.stub(foreign, "HEAD", "/download", fn conn ->
      Plug.Conn.resp(conn, 200, "")
    end)

    Bypass.stub(foreign, "GET", "/download", fn conn ->
      send(test_pid, {:foreign_cookie_header, Plug.Conn.get_req_header(conn, "cookie")})
      Plug.Conn.resp(conn, 200, "d8:announce")
    end)

    Queue.select_and_add_to_client(search_result("http://localhost:#{home.port}/download"), [])

    assert_receive {:home_cookie_header, ["session=topsecret"]}, 2_000
    assert_receive {:foreign_cookie_header, foreign_cookie_header}, 2_000
    assert foreign_cookie_header == []
  end
end
