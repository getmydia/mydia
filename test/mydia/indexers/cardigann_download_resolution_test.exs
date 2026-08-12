defmodule Mydia.Indexers.CardigannDownloadResolutionTest do
  use Mydia.DataCase, async: true

  alias Mydia.Indexers
  alias Mydia.Indexers.CardigannDefinition
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
end
