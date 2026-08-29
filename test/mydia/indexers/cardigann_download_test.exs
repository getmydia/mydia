defmodule Mydia.Indexers.CardigannDownloadTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.CardigannDefinition.Parsed
  alias Mydia.Indexers.CardigannDownload
  alias Mydia.Indexers.CardigannParser

  @info_hash "d2e202a5d71ea60b26203f2a9003a1e569382096"
  @title "Ted.Lasso.S04E02.1080p.10bit.WEBRip.6CH.x265.HEVC-PSA.mkv"

  # Trimmed copy of a real www.magnetdownload.com /api/json_info response.
  @json_info ~s({"result": [{"category": "video", "name": "#{@title}", ) <>
               ~s("info_hash": "#{@info_hash}", "length": 576012298, "id": 24845983}], "ret": 0})

  @selector_definition """
  ---
  id: selectortest
  name: Selector Test
  description: "Resolves its download link out of the landing page"
  language: en-US
  type: public
  encoding: UTF-8
  links:
    - https://selector.example/

  caps:
    modes:
      search: [q]

  download:
    selectors:
      - selector: a.download-link
        attribute: href

  search:
    paths:
      - path: search
    rows:
      selector: tr
    fields:
      title:
        selector: a
      size:
        selector: td.size
      seeders:
        selector: td.seeds
  """

  # Plenty of definitions (torrentgalaxyclone, 1337x, eztv, nyaasi) point their
  # download selector straight at a magnet on the details page.
  @magnet_selector_definition """
  ---
  id: magnetselectortest
  name: Magnet Selector Test
  description: "Points its download selector straight at a magnet"
  language: en-US
  type: public
  encoding: UTF-8
  links:
    - https://magnetselector.example/

  caps:
    modes:
      search: [q]

  download:
    selectors:
      - selector: a[href^="magnet:?xt="]
        attribute: href

  search:
    paths:
      - path: search
    rows:
      selector: tr
    fields:
      title:
        selector: a
      size:
        selector: td.size
      seeders:
        selector: td.seeds
  """

  @landing_page """
  <html><body>
    <h1>#{@title}</h1>
    <a class="other" href="/info/1">details</a>
    <a class="download-link" href="/get/24845983.torrent">download</a>
  </body></html>
  """

  @magnet_landing_page """
  <html><body>
    <h1>#{@title}</h1>
    <a class="other" href="/info/1">details</a>
    <a href="magnet:?xt=urn:btih:#{@info_hash}&amp;dn=Ted.Lasso">magnet</a>
  </body></html>
  """

  defp magnetdownload_definition(port) do
    {:ok, parsed} =
      "test/fixtures/cardigann/magnetdownload.yml"
      |> File.read!()
      |> CardigannParser.parse_definition()

    %{parsed | links: ["http://localhost:#{port}/"]}
  end

  defp selector_definition(port) do
    {:ok, parsed} = CardigannParser.parse_definition(@selector_definition)
    %{parsed | links: ["http://localhost:#{port}/"]}
  end

  defp magnet_selector_definition(port) do
    {:ok, parsed} = CardigannParser.parse_definition(@magnet_selector_definition)
    %{parsed | links: ["http://localhost:#{port}/"]}
  end

  # A definition whose infohash block reads the landing page directly rather
  # than a before-response.
  defp direct_infohash_definition(port) do
    %Parsed{
      id: "directhash",
      name: "Direct Hash",
      type: "public",
      encoding: "UTF-8",
      links: ["http://localhost:#{port}/"],
      capabilities: %{modes: %{}},
      search: %{paths: [%{path: "/search"}], rows: %{selector: "tr"}, fields: %{}},
      download: %{
        selectors: [],
        before: nil,
        method: "get",
        infohash: %{
          usebeforeresponse: false,
          hash: %{selector: ":root", filters: [%{"name" => "regexp", "args" => "([a-f0-9]{40})"}]},
          title: %{
            selector: ":root",
            filters: [%{"name" => "regexp", "args" => "<h1>(.+?)</h1>"}]
          }
        }
      }
    }
  end

  describe "resolve/3 with a before-request and an infohash block" do
    test "builds a magnet from the hash in the before-response" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/api/json_info", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.query_params["hashes"] == "24845983"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, @json_info)
      end)

      definition = magnetdownload_definition(bypass.port)
      url = "http://localhost:#{bypass.port}/info/24845983"

      assert {:ok, {:magnet, magnet}} = CardigannDownload.resolve(definition, url)
      assert magnet =~ "xt=urn:btih:#{@info_hash}"
      assert magnet =~ "Ted.Lasso.S04E02"
    end

    test "returns an error when the hash selector matches nothing" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/api/json_info", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"result": [], "ret": 1}))
      end)

      definition = magnetdownload_definition(bypass.port)
      url = "http://localhost:#{bypass.port}/info/24845983"

      assert {:error, {:cardigann_download, message}} =
               CardigannDownload.resolve(definition, url)

      assert message =~ "hash"
    end

    test "still builds a magnet when only the title selector fails to match" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/api/json_info", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"info_hash": "#{@info_hash}", "ret": 0}))
      end)

      definition = magnetdownload_definition(bypass.port)
      url = "http://localhost:#{bypass.port}/info/24845983"

      assert {:ok, {:magnet, magnet}} = CardigannDownload.resolve(definition, url)
      assert magnet =~ "xt=urn:btih:#{@info_hash}"
    end
  end

  describe "resolve/3 with an infohash block that reads the landing page" do
    test "fetches the download url when usebeforeresponse is not set" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/info/24845983", fn conn ->
        Plug.Conn.resp(
          conn,
          200,
          "<html><body><h1>#{@title}</h1><p>#{@info_hash}</p></body></html>"
        )
      end)

      definition = direct_infohash_definition(bypass.port)
      url = "http://localhost:#{bypass.port}/info/24845983"

      assert {:ok, {:magnet, magnet}} = CardigannDownload.resolve(definition, url)
      assert magnet =~ "xt=urn:btih:#{@info_hash}"
    end
  end

  describe "resolve/3 with a selectors block" do
    test "returns the link the selector points at, made absolute" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/info/24845983", fn conn ->
        Plug.Conn.resp(conn, 200, @landing_page)
      end)

      definition = selector_definition(bypass.port)
      url = "http://localhost:#{bypass.port}/info/24845983"

      assert {:ok, {:link, link}} = CardigannDownload.resolve(definition, url)
      assert link == "http://localhost:#{bypass.port}/get/24845983.torrent"
    end

    # A magnet handed back as {:link, ...} would be fetched over HTTP by the
    # grab path, which cannot speak the magnet scheme.
    test "returns a magnet, not a link, when the selector points at one" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/info/24845983", fn conn ->
        Plug.Conn.resp(conn, 200, @magnet_landing_page)
      end)

      definition = magnet_selector_definition(bypass.port)
      url = "http://localhost:#{bypass.port}/info/24845983"

      assert {:ok, {:magnet, magnet}} = CardigannDownload.resolve(definition, url)
      assert magnet =~ "xt=urn:btih:#{@info_hash}"
    end
  end

  describe "resolve/3 when there is nothing to resolve" do
    test "returns :not_applicable for a definition with no download block" do
      definition = %Parsed{
        id: "plain",
        name: "Plain",
        type: "public",
        links: ["https://plain.example/"],
        capabilities: %{modes: %{}},
        search: %{paths: [%{path: "/search"}], rows: %{selector: "tr"}, fields: %{}},
        download: nil
      }

      assert :not_applicable =
               CardigannDownload.resolve(definition, "https://plain.example/info/1")
    end
  end

  # Phase 1 stores a probed active_link; without honouring it here, a definition
  # that failed over to a mirror still resolves its download block against the
  # dead primary in `links` head.
  describe "resolve/3 with a configured base_url" do
    test "resolves the download block against the configured base_url, not links head" do
      dead = Bypass.open()
      live = Bypass.open()
      Bypass.down(dead)

      Bypass.expect(live, "GET", "/dl/1", fn conn ->
        Plug.Conn.resp(
          conn,
          200,
          ~s|<html><body><a href="magnet:?xt=urn:btih:VIALIVE">m</a></body></html>|
        )
      end)

      dead_url = "http://localhost:#{dead.port}"
      live_url = "http://localhost:#{live.port}"

      definition = %Parsed{
        id: "base-url-test",
        name: "Base URL Test",
        type: "public",
        encoding: "UTF-8",
        links: [dead_url],
        capabilities: %{modes: %{}},
        search: %{paths: [%{path: "/search"}], rows: %{selector: "tr"}, fields: %{}},
        download: %{
          selectors: [%{selector: ~s|a[href^="magnet:"]|, attribute: "href"}]
        }
      }

      assert {:ok, {:magnet, magnet}} =
               CardigannDownload.resolve(definition, "/dl/1", %{base_url: live_url})

      assert magnet =~ "VIALIVE"
    end
  end

  describe "credential scope on downloads" do
    test "a download url on a foreign host does not receive the session" do
      site = Bypass.open()
      foreign = Bypass.open()
      test_pid = self()

      Bypass.expect_once(foreign, "GET", "/get.torrent", fn conn ->
        send(test_pid, {:cookie_header, Plug.Conn.get_req_header(conn, "cookie")})
        Plug.Conn.resp(conn, 200, "d8:announce")
      end)

      definition = %Parsed{
        id: "dl-scope",
        name: "DL Scope",
        description: "",
        language: "en-US",
        type: "private",
        encoding: "UTF-8",
        links: ["http://localhost:#{site.port}"],
        capabilities: %{modes: %{}},
        search: %{paths: [%{path: "/search"}], inputs: %{}, rows: %{}, fields: %{}},
        login: nil,
        download: %{selectors: [%{selector: "a.dl", attribute: "href"}]},
        settings: [],
        request_delay: nil,
        follow_redirect: false
      }

      CardigannDownload.resolve(definition, "http://localhost:#{foreign.port}/get.torrent", %{
        cookies: ["session=secret"],
        base_url: "http://localhost:#{site.port}",
        config: %{}
      })

      assert_receive {:cookie_header, []}
    end

    test "a download url on the site host does receive the session" do
      site = Bypass.open()
      test_pid = self()

      Bypass.expect_once(site, "GET", "/get.torrent", fn conn ->
        send(test_pid, {:cookie_header, Plug.Conn.get_req_header(conn, "cookie")})
        Plug.Conn.resp(conn, 200, "d8:announce")
      end)

      definition = %Parsed{
        id: "dl-scope-ok",
        name: "DL Scope OK",
        description: "",
        language: "en-US",
        type: "private",
        encoding: "UTF-8",
        links: ["http://localhost:#{site.port}"],
        capabilities: %{modes: %{}},
        search: %{paths: [%{path: "/search"}], inputs: %{}, rows: %{}, fields: %{}},
        login: nil,
        download: %{selectors: [%{selector: "a.dl", attribute: "href"}]},
        settings: [],
        request_delay: nil,
        follow_redirect: false
      }

      CardigannDownload.resolve(definition, "/get.torrent", %{
        cookies: ["session=secret"],
        base_url: "http://localhost:#{site.port}",
        config: %{}
      })

      assert_receive {:cookie_header, ["session=secret"]}
    end

    # The two tests above hold on with the interim `%{}` config Task 3 passed
    # in: link-based scoping alone already decides them, so they cannot tell
    # `scope_config/1` threading the operator's settings through from a
    # regression that drops those settings back to `%{}`. This test can: the
    # download host is named only by a templated `{{ .Config.apiurl }}`
    # search path, resolvable exclusively from the operator's own config, not
    # from the definition's shipped default.
    test "a download url reachable only via the operator's configured api host receives the session" do
      site = Bypass.open()
      api = Bypass.open()
      test_pid = self()

      Bypass.expect_once(api, "GET", "/get.torrent", fn conn ->
        send(test_pid, {:cookie_header, Plug.Conn.get_req_header(conn, "cookie")})
        Plug.Conn.resp(conn, 200, "d8:announce")
      end)

      definition = %Parsed{
        id: "dl-scope-apiurl",
        name: "DL Scope Apiurl",
        description: "",
        language: "en-US",
        type: "private",
        encoding: "UTF-8",
        links: ["http://localhost:#{site.port}"],
        capabilities: %{modes: %{}},
        search: %{
          paths: [%{path: "https://{{ .Config.apiurl }}/search"}],
          inputs: %{},
          rows: %{},
          fields: %{}
        },
        login: nil,
        download: %{selectors: [%{selector: "a.dl", attribute: "href"}]},
        settings: [%{name: "apiurl", type: "text", default: "unused.invalid"}],
        request_delay: nil,
        follow_redirect: false
      }

      CardigannDownload.resolve(definition, "http://localhost:#{api.port}/get.torrent", %{
        cookies: ["session=secret"],
        base_url: "http://localhost:#{site.port}",
        config: %{"apiurl" => "localhost:#{api.port}"}
      })

      assert_receive {:cookie_header, ["session=secret"]}
    end
  end
end
