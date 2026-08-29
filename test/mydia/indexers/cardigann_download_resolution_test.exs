defmodule Mydia.Indexers.CardigannDownloadResolutionTest do
  use Mydia.DataCase, async: true

  alias Mydia.Indexers
  alias Mydia.Indexers.CardigannDefinition
  alias Mydia.Indexers.CardigannSearchSession
  alias Mydia.Repo

  @info_hash "d2e202a5d71ea60b26203f2a9003a1e569382096"
  @title "Ted.Lasso.S04E02.1080p.10bit.WEBRip.6CH.x265.HEVC-PSA.mkv"

  @json_info ~s({"result": [{"name": "#{@title}", "info_hash": "#{@info_hash}"}], "ret": 0})

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

  describe "resolve_cardigann_download/2" do
    test "turns a stored definition's download block into a magnet" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/api/json_info", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, @json_info)
      end)

      store_definition!(bypass.port)

      assert {:ok, {:magnet, magnet}} =
               Indexers.resolve_cardigann_download(
                 "MagnetDownload",
                 "http://localhost:#{bypass.port}/info/24845983"
               )

      assert magnet =~ "xt=urn:btih:#{@info_hash}"
    end

    test "returns :not_applicable for an indexer with no stored definition" do
      assert :not_applicable =
               Indexers.resolve_cardigann_download("Nonexistent", "https://example.test/info/1")
    end

    test "returns :not_applicable when the indexer name is nil" do
      assert :not_applicable = Indexers.resolve_cardigann_download(nil, "https://example.test/x")
    end
  end

  # resolve_cardigann_download/2 is the seam that plumbs a stored definition's
  # operator config into CardigannDownload.resolve/3. A test that calls
  # CardigannDownload.resolve/3 directly cannot catch a regression at that
  # seam, e.g. indexers.ex passing the wrong field as :config: it would still
  # compile, and every test aimed at CardigannDownload itself would still
  # pass. This exercises resolve_cardigann_download/2 itself, with a real
  # stored CardigannDefinition and a real stored CardigannSearchSession, so
  # the cookies genuinely come from the database the way get_cardigann_auth_
  # cookies/1 reads them, not from a user_config map built by the test.
  describe "resolve_cardigann_download/2 threads the stored operator config" do
    test "a download host named only by the operator's apiurl setting still receives the session" do
      site = Bypass.open()
      api = Bypass.open()
      test_pid = self()

      Bypass.expect_once(api, "GET", "/get.torrent", fn conn ->
        send(test_pid, {:cookie_header, Plug.Conn.get_req_header(conn, "cookie")})
        Plug.Conn.resp(conn, 200, "d8:announce")
      end)

      # The shipped default (`unused.invalid`) is not the api Bypass host, so
      # only the operator's stored config below can land the api origin in
      # the trusted set.
      yaml = """
      id: dl-scope-apiurl-db
      name: DL Scope Apiurl DB
      description: "Resolves a download host named only by the operator's apiurl setting"
      language: en-US
      type: private
      encoding: UTF-8
      links:
        - http://localhost:#{site.port}/

      caps:
        modes:
          search: [q]

      settings:
        - name: apiurl
          type: text
          default: unused.invalid

      search:
        paths:
          - path: "http://{{ .Config.apiurl }}/search"
        rows:
          selector: tr
        fields:
          title:
            selector: a
          size:
            text: 1
          seeders:
            text: 1

      download:
        selectors:
          - selector: a.dl
            attribute: href
      """

      definition =
        %CardigannDefinition{}
        |> CardigannDefinition.changeset(%{
          indexer_id: "dl-scope-apiurl-db",
          name: "DL Scope Apiurl DB",
          type: "private",
          links: %{"main" => "http://localhost:#{site.port}/"},
          capabilities: %{},
          definition: yaml,
          schema_version: "1",
          enabled: true,
          config: %{"apiurl" => "localhost:#{api.port}"}
        })
        |> Repo.insert!()

      %CardigannSearchSession{}
      |> CardigannSearchSession.changeset(%{
        cookies: ["session=secret"],
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        cardigann_definition_id: definition.id
      })
      |> Repo.insert!()

      Indexers.resolve_cardigann_download(
        "DL Scope Apiurl DB",
        "http://localhost:#{api.port}/get.torrent"
      )

      assert_receive {:cookie_header, ["session=secret"]}
    end
  end
end
