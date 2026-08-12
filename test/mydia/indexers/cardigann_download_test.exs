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

  @landing_page """
  <html><body>
    <h1>#{@title}</h1>
    <a class="other" href="/info/1">details</a>
    <a class="download-link" href="/get/24845983.torrent">download</a>
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
end
