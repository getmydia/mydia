defmodule Mydia.Indexers.Cardigann.Bench.OracleTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.Cardigann.Bench.{Oracle, Release}
  alias Mydia.Indexers.SearchResult

  @hash "0123456789abcdef0123456789abcdef01234567"
  @proxied "http://localhost:9696/3/download?apikey=SECRETKEY&link=ZW5jcnlwdGVk&file=Film"

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass, oracle: Oracle.new("http://localhost:#{bypass.port}/", "test-key")}
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end

  defp query(conn), do: Plug.Conn.fetch_query_params(conn).query_params

  defp codec_query(overrides) do
    Map.merge(
      %{
        kind: :search,
        term: "ubuntu",
        categories: [],
        imdb_id: nil,
        tmdb_id: nil,
        tvdb_id: nil,
        season: nil,
        episode: nil,
        limit: nil,
        offset: nil
      },
      overrides
    )
  end

  describe "ensure_indexer/3" do
    test "returns the id of an existing indexer without creating one", %{
      bypass: bypass,
      oracle: oracle
    } do
      Bypass.expect_once(bypass, "GET", "/api/v1/indexer", fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-api-key") == ["test-key"]
        json(conn, 200, [%{"id" => 7, "definitionName" => "demo"}])
      end)

      assert {:ok, 7} = Oracle.ensure_indexer(oracle, "demo", %{})
    end

    test "creates from the schema, filling fields from settings", %{
      bypass: bypass,
      oracle: oracle
    } do
      Bypass.expect_once(bypass, "GET", "/api/v1/indexer", fn conn -> json(conn, 200, []) end)

      Bypass.expect_once(bypass, "GET", "/api/v1/indexer/schema", fn conn ->
        json(conn, 200, [
          %{"definitionName" => "other", "fields" => []},
          %{
            "definitionName" => "demo",
            "enable" => false,
            "fields" => [
              %{"name" => "username", "value" => ""},
              %{"name" => "sort", "value" => "created"}
            ]
          }
        ])
      end)

      Bypass.expect_once(bypass, "POST", "/api/v1/indexer", fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)
        assert body["definitionName"] == "demo"
        assert body["enable"] == true
        assert body["appProfileId"] == 1

        assert body["fields"] == [
                 %{"name" => "username", "value" => "me"},
                 %{"name" => "sort", "value" => "created"}
               ]

        json(conn, 201, Map.put(body, "id", 12))
      end)

      assert {:ok, 12} = Oracle.ensure_indexer(oracle, "demo", %{"username" => "me"})
    end

    test "errors when the definition is not in the schema", %{bypass: bypass, oracle: oracle} do
      Bypass.expect_once(bypass, "GET", "/api/v1/indexer", fn conn -> json(conn, 200, []) end)

      Bypass.expect_once(bypass, "GET", "/api/v1/indexer/schema", fn conn ->
        json(conn, 200, [%{"definitionName" => "other", "fields" => []}])
      end)

      assert {:error, :definition_not_found} = Oracle.ensure_indexer(oracle, "demo", %{})
    end

    test "surfaces http errors", %{bypass: bypass, oracle: oracle} do
      Bypass.expect_once(bypass, "GET", "/api/v1/indexer", fn conn ->
        json(conn, 401, %{"error" => "Unauthorized"})
      end)

      assert {:error, {:http_status, 401, _}} = Oracle.ensure_indexer(oracle, "demo", %{})
    end
  end

  describe "search/3" do
    test "sends a plain search and decodes releases", %{bypass: bypass, oracle: oracle} do
      Bypass.expect_once(bypass, "GET", "/api/v1/search", fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-api-key") == ["test-key"]
        q = query(conn)
        assert q["query"] == "ubuntu"
        assert q["type"] == "search"
        assert q["indexerIds"] == "3"
        assert q["limit"] == "100"

        json(conn, 200, [
          %{
            "title" => "Ubuntu 24.04",
            "size" => 5_000,
            "infoHash" => String.upcase(@hash),
            "downloadUrl" => @proxied,
            "magnetUrl" => nil,
            "seeders" => 10,
            "leechers" => 2,
            "publishDate" => "2026-01-02T03:04:05Z"
          }
        ])
      end)

      assert {:ok, [release]} = Oracle.search(oracle, 3, codec_query(%{limit: 100}))

      assert %Release{
               title: "Ubuntu 24.04",
               size: 5_000,
               info_hash: @hash,
               download_url: nil,
               seeders: 10,
               peers: 2,
               publish_date: ~U[2026-01-02 03:04:05Z]
             } = release

      refute inspect(release) =~ "SECRETKEY"
    end

    test "maps tv kind to tvsearch with ids and categories", %{bypass: bypass, oracle: oracle} do
      Bypass.expect_once(bypass, "GET", "/api/v1/search", fn conn ->
        raw = conn.query_string
        q = query(conn)
        assert q["type"] == "tvsearch"
        assert q["query"] == "show{tvdbid:81189}{season:2}{episode:5}"
        assert raw =~ "categories=5000"
        assert raw =~ "categories=5040"
        json(conn, 200, [])
      end)

      query =
        codec_query(%{
          kind: :tv,
          term: "show",
          categories: [5000, 5040],
          tvdb_id: 81189,
          season: 2,
          episode: "5"
        })

      assert {:ok, []} = Oracle.search(oracle, 3, query)
    end

    test "maps movie kind with imdb id and falls back to the magnet link", %{
      bypass: bypass,
      oracle: oracle
    } do
      Bypass.expect_once(bypass, "GET", "/api/v1/search", fn conn ->
        q = query(conn)
        assert q["type"] == "movie"
        assert q["query"] == "film{imdbid:tt0133093}"

        json(conn, 200, [
          %{
            "title" => "Film",
            "size" => 0,
            "infoHash" => nil,
            "downloadUrl" => nil,
            "magnetUrl" => @proxied,
            "seeders" => nil,
            "leechers" => nil,
            "publishDate" => nil
          }
        ])
      end)

      query = codec_query(%{kind: :movie, term: "film", imdb_id: "tt0133093"})
      assert {:ok, [release]} = Oracle.search(oracle, 3, query)
      assert release.info_hash == nil
      assert release.download_url == nil
      assert release.size == nil
      refute inspect(release) =~ "SECRETKEY"
      assert release.seeders == nil
    end

    test "surfaces http errors", %{bypass: bypass, oracle: oracle} do
      Bypass.expect_once(bypass, "GET", "/api/v1/search", fn conn ->
        json(conn, 400, %{"message" => "boom"})
      end)

      assert {:error, {:http_status, 400, _}} = Oracle.search(oracle, 3, codec_query(%{}))
    end
  end

  describe "Release" do
    test "base32 and hex btih normalise to the same lowercase hex on both sides" do
      b32 = @hash |> Base.decode16!(case: :lower) |> Base.encode32(padding: false)
      assert byte_size(b32) == 32

      for form <- [b32, String.downcase(b32), String.upcase(@hash), @hash] do
        sr = %SearchResult{
          title: "T",
          size: 1,
          seeders: 1,
          leechers: 0,
          download_url: "magnet:?xt=urn:btih:#{form}",
          indexer: "x"
        }

        assert Release.from_search_result(sr).info_hash == @hash
        assert Release.from_prowlarr(%{"infoHash" => form}).info_hash == @hash
      end
    end

    test "from_search_result/1 derives the hash from a magnet link" do
      result = %SearchResult{
        title: "T",
        size: 9,
        seeders: 4,
        leechers: 1,
        download_url: "magnet:?dn=T&xt=urn:btih:#{String.upcase(@hash)}",
        indexer: "x",
        published_at: ~U[2026-01-02 03:04:05Z]
      }

      assert %Release{
               title: "T",
               size: 9,
               info_hash: @hash,
               seeders: 4,
               peers: 1,
               publish_date: ~U[2026-01-02 03:04:05Z]
             } = Release.from_search_result(result)
    end

    test "from_search_result/1 prefers a hash in metadata and tolerates a plain url" do
      with_meta = %SearchResult{
        title: "T",
        size: 1,
        seeders: nil,
        leechers: nil,
        download_url: "http://x/y.torrent",
        indexer: "x",
        metadata: %{info_hash: String.upcase(@hash)}
      }

      assert Release.from_search_result(with_meta).info_hash == @hash

      plain = %{with_meta | metadata: nil}
      assert Release.from_search_result(plain).info_hash == nil
    end
  end
end
