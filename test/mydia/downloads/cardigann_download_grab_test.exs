defmodule Mydia.Downloads.CardigannDownloadGrabTest do
  @moduledoc """
  The grab path must honour a Cardigann `download:` block.

  Indexers like MagnetDownload publish a landing page as the row's download
  link and build the magnet in client-side JavaScript, so fetching that link
  yields HTML with no magnet anywhere in it. The definition says how to derive
  the magnet instead; the grab path has to follow it.
  """
  use Mydia.DataCase, async: false

  alias Mydia.Downloads.Queue
  alias Mydia.Indexers.CardigannDefinition
  alias Mydia.Indexers.SearchResult
  alias Mydia.Repo

  @info_hash "d2e202a5d71ea60b26203f2a9003a1e569382096"
  @title "Ted.Lasso.S04E02.1080p.10bit.WEBRip.6CH.x265.HEVC-PSA.mkv"

  @json_info ~s({"result": [{"name": "#{@title}", "info_hash": "#{@info_hash}"}], "ret": 0})

  # What the real site serves at /info/<id>: the magnet is assembled in JS from
  # an XHR, so the markup contains no magnet link and no infohash.
  @landing_page """
  <html><head><title>#{@title}</title></head><body>
  <script>var link1 = 'magnet:' + '?xt=urn' + ':btih:' + info.info_hash;</script>
  </body></html>
  """

  defp store_definition!(port) do
    yaml =
      "test/fixtures/cardigann/magnetdownload.yml"
      |> File.read!()
      |> String.replace("https://www.magnetdownload.com/", "http://localhost:#{port}/")

    %CardigannDefinition{}
    |> CardigannDefinition.changeset(%{
      indexer_id: "magnetdownload",
      name: "MagnetDownload",
      type: "public",
      links: %{"main" => "http://localhost:#{port}/"},
      capabilities: %{},
      definition: yaml,
      schema_version: "1",
      enabled: true
    })
    |> Repo.insert!()
  end

  test "derives the magnet from the definition instead of fetching the landing page" do
    test_pid = self()
    bypass = Bypass.open()

    Bypass.stub(bypass, "GET", "/api/json_info", fn conn ->
      params = Plug.Conn.fetch_query_params(conn).query_params
      send(test_pid, {:metadata_api_called, params})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, @json_info)
    end)

    Bypass.stub(bypass, "GET", "/info/24845983", fn conn ->
      send(test_pid, :landing_page_fetched)
      Plug.Conn.resp(conn, 200, @landing_page)
    end)

    store_definition!(bypass.port)

    search_result = %SearchResult{
      title: @title,
      indexer: "MagnetDownload",
      download_url: "http://localhost:#{bypass.port}/info/24845983",
      size: 576_012_298,
      seeders: 1,
      leechers: 1,
      download_protocol: :torrent
    }

    # No download client is configured, so this fails at client selection - but
    # only after the torrent input has been prepared, which is the step at test.
    Queue.select_and_add_to_client(search_result, [])

    assert_receive {:metadata_api_called, %{"hashes" => "24845983"}}, 2_000
    refute_received :landing_page_fetched
  end
end
