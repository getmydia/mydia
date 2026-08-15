defmodule Mydia.Media.RefreshTest do
  use Mydia.DataCase, async: false

  import ExUnit.CaptureLog
  import Mydia.MediaFixtures

  alias Mydia.Media.MediaItem
  alias Mydia.Media.Refresh
  alias Mydia.Metadata.Structs.MediaMetadata

  # MediaMetadata enforces :provider_id, :provider and :media_type, so every
  # literal needs them. Default provider_id to "" (which is what
  # MetadataType.map_to_struct/1 stores when there is no id) so tests that care
  # about `id` are not silently satisfied by `provider_id`.
  defp metadata(attrs) do
    defaults = %{provider_id: "", provider: :metadata_relay, media_type: :movie}
    struct!(MediaMetadata, Map.merge(defaults, Map.new(attrs)))
  end

  describe "resolve_provider/1" do
    test "metadata_source :tmdb wins over a back-filled tvdb_id" do
      item = %MediaItem{metadata_source: :tmdb, tmdb_id: 111, tvdb_id: 222}
      assert Refresh.resolve_provider(item) == {111, :tmdb}
    end

    test "metadata_source :tvdb wins over a present tmdb_id" do
      item = %MediaItem{metadata_source: :tvdb, tmdb_id: 111, tvdb_id: 222}
      assert Refresh.resolve_provider(item) == {222, :tvdb}
    end

    test "without metadata_source, tvdb_id takes legacy precedence" do
      item = %MediaItem{metadata_source: nil, tmdb_id: 111, tvdb_id: 222}
      assert Refresh.resolve_provider(item) == {222, :tvdb}
    end

    test "falls back to tmdb_id when no tvdb_id is present" do
      item = %MediaItem{metadata_source: nil, tmdb_id: 111, tvdb_id: nil}
      assert Refresh.resolve_provider(item) == {111, :tmdb}
    end

    # REGRESSION: this is the exact shape that raised in
    # metadata_refresh.ex:306 via `media_item.metadata["id"]`.
    # provider_id is deliberately different so this proves `id` is read and wins.
    test "falls back to metadata.id when both provider id columns are nil" do
      item = %MediaItem{
        tmdb_id: nil,
        tvdb_id: nil,
        metadata: metadata(id: 12_345, provider_id: "999")
      }

      assert Refresh.resolve_provider(item) == {12_345, :tmdb}
    end

    test "parses a string metadata.id" do
      item = %MediaItem{tmdb_id: nil, tvdb_id: nil, metadata: metadata(id: "678")}
      assert Refresh.resolve_provider(item) == {678, :tmdb}
    end

    test "falls back to metadata.provider_id when metadata.id is nil" do
      item = %MediaItem{
        tmdb_id: nil,
        tvdb_id: nil,
        metadata: metadata(id: nil, provider_id: "999")
      }

      assert Refresh.resolve_provider(item) == {999, :tmdb}
    end

    # MetadataType.map_to_struct/1 sets provider_id to `to_string(data[:id] || "")`,
    # so an empty string is common — and truthy in Elixir.
    # The stored blob records its own provenance: fetch_tvdb_by_id/3 stamps
    # provider: :tvdb, while the TMDB path leaves from_api_response/3's default
    # of :metadata_relay. Labelling a TVDB id as :tmdb routes it to
    # /tmdb/tv/shows/<tvdb-id> and fetches an unrelated show.
    test "a TVDB-sourced blob resolves to :tvdb, not :tmdb" do
      item = %MediaItem{
        type: "tv_show",
        tmdb_id: nil,
        tvdb_id: nil,
        metadata: metadata(id: 4242, provider: :tvdb, media_type: :tv_show)
      }

      assert Refresh.resolve_provider(item) == {4242, :tvdb}
    end

    test "a relay-sourced blob still resolves to :tmdb" do
      item = %MediaItem{
        type: "tv_show",
        tmdb_id: nil,
        tvdb_id: nil,
        metadata: metadata(id: 555, provider: :metadata_relay, media_type: :tv_show)
      }

      assert Refresh.resolve_provider(item) == {555, :tmdb}
    end

    test "metadata_source outranks the blob's own provider" do
      item = %MediaItem{
        type: "tv_show",
        metadata_source: :tmdb,
        tmdb_id: nil,
        tvdb_id: nil,
        metadata: metadata(id: 777, provider: :tvdb, media_type: :tv_show)
      }

      assert Refresh.resolve_provider(item) == {777, :tmdb}
    end

    test "an empty provider_id resolves to no provider, not a bogus id" do
      item = %MediaItem{
        tmdb_id: nil,
        tvdb_id: nil,
        metadata: metadata(id: nil, provider_id: "")
      }

      assert Refresh.resolve_provider(item) == {nil, nil}
    end

    test "an unparseable metadata id resolves to no provider" do
      item = %MediaItem{
        tmdb_id: nil,
        tvdb_id: nil,
        metadata: metadata(id: "abc", provider_id: "xyz")
      }

      assert Refresh.resolve_provider(item) == {nil, nil}
    end

    test "nil metadata resolves to no provider" do
      item = %MediaItem{tmdb_id: nil, tvdb_id: nil, metadata: nil}
      assert Refresh.resolve_provider(item) == {nil, nil}
    end

    test "a legacy plain-map metadata resolves to no provider instead of raising" do
      item = %MediaItem{tmdb_id: nil, tvdb_id: nil, metadata: %{"id" => 5}}
      assert Refresh.resolve_provider(item) == {nil, nil}
    end
  end

  describe "run/2" do
    setup do
      bypass = Bypass.open()

      # Inject the relay config directly so this test never mutates the global
      # METADATA_RELAY_URL env var (which would race concurrent async tests).
      config = %{
        type: :metadata_relay,
        base_url: "http://localhost:#{bypass.port}",
        options: %{language: "en-US", include_adult: false}
      }

      %{bypass: bypass, config: config}
    end

    test "refreshes a movie and syncs the wide attribute set", %{
      bypass: bypass,
      config: config
    } do
      item = media_item_fixture(%{type: "movie", title: "Stale Title", year: 1999, tmdb_id: 555})

      Bypass.expect_once(bypass, "GET", "/tmdb/movies/555", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "id" => 555,
            "title" => "Fresh Title",
            "original_title" => "Fresh Original",
            "release_date" => "2020-05-01",
            "imdb_id" => "tt7654321",
            "overview" => "x",
            "credits" => %{"cast" => [], "crew" => []},
            "genres" => []
          })
        )
      end)

      assert {:ok, updated} = Refresh.run(item, config: config)

      assert updated.title == "Fresh Title"
      assert updated.original_title == "Fresh Original"
      assert updated.year == 2020
      assert updated.imdb_id == "tt7654321"
      assert updated.tmdb_id == 555
    end

    # The job's resolver ignored metadata_source entirely, so it would have
    # fetched this show from TVDB. Only the TMDB path is stubbed, so a
    # wrong-provider fetch 404s and fails the test.
    test "a TMDB-sourced show with a back-filled tvdb_id refreshes from TMDB", %{
      bypass: bypass,
      config: config
    } do
      item =
        media_item_fixture(%{
          type: "tv_show",
          title: "TMDB Sourced",
          metadata_source: :tmdb,
          tmdb_id: 12_345,
          tvdb_id: 67_890
        })

      Bypass.expect_once(bypass, "GET", "/tmdb/tv/shows/12345", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "id" => 12_345,
            "name" => "TMDB Sourced",
            "first_air_date" => "2010-01-01",
            "overview" => "x",
            "credits" => %{"cast" => [], "crew" => []},
            "genres" => [],
            "seasons" => []
          })
        )
      end)

      assert {:ok, updated} = Refresh.run(item, config: config, fetch_episodes: false)
      assert updated.tmdb_id == 12_345
    end

    test "returns :missing_provider_id and makes no request when nothing resolves", %{
      bypass: bypass,
      config: config
    } do
      item = media_item_fixture(%{type: "movie", title: "No Ids", year: 2024, tmdb_id: nil})

      Bypass.stub(bypass, "GET", "/tmdb/movies/search", fn _conn ->
        flunk("run/2 must not search when recover_by_title is not set")
      end)

      assert {:error, :missing_provider_id} = Refresh.run(item, config: config)
    end

    test "recovers a TV show by title and routes the id to tvdb_id", %{
      bypass: bypass,
      config: config
    } do
      item =
        media_item_fixture(%{
          type: "tv_show",
          title: "Recoverable Show",
          tmdb_id: nil,
          tvdb_id: nil
        })

      Bypass.expect_once(bypass, "GET", "/tvdb/search", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "data" => [
              %{
                "tvdb_id" => "4242",
                "name" => "Recoverable Show",
                "year" => "2015",
                "type" => "series"
              }
            ]
          })
        )
      end)

      Bypass.expect_once(bypass, "GET", "/tvdb/series/4242/extended", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "data" => %{
              "id" => 4242,
              "name" => "Recoverable Show",
              "firstAired" => "2015-03-01",
              "overview" => "x",
              "genres" => [],
              "seasons" => [],
              "characters" => []
            }
          })
        )
      end)

      assert {:ok, updated} =
               Refresh.run(item,
                 config: config,
                 recover_by_title: true,
                 fetch_episodes: false
               )

      assert updated.tvdb_id == 4242
      refute updated.tmdb_id == 4242
    end

    test "backfills the cross-referenced provider id from TVDB remoteIds", %{
      bypass: bypass,
      config: config
    } do
      item =
        media_item_fixture(%{
          type: "tv_show",
          title: "Cross Referenced",
          metadata_source: :tvdb,
          tvdb_id: 4243,
          tmdb_id: nil
        })

      Bypass.expect_once(bypass, "GET", "/tvdb/series/4243/extended", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "data" => %{
              "id" => 4243,
              "name" => "Cross Referenced",
              "firstAired" => "2015-03-01",
              "overview" => "x",
              "genres" => [],
              "seasons" => [],
              "characters" => [],
              "trailers" => [%{"url" => "https://youtube.com/watch?v=a", "language" => "eng"}],
              "remoteIds" => [
                %{"sourceName" => "TheMovieDB.com", "id" => "7777", "type" => 12},
                %{"sourceName" => "IMDB", "id" => "tt7777777", "type" => 2}
              ]
            }
          })
        )
      end)

      assert {:ok, updated} = Refresh.run(item, config: config, fetch_episodes: false)

      assert updated.tvdb_id == 4243
      assert updated.tmdb_id == 7777
      assert updated.imdb_id == "tt7777777"
    end

    test "skips a cross-referenced id another row already owns", %{
      bypass: bypass,
      config: config
    } do
      media_item_fixture(%{type: "tv_show", title: "Incumbent", tmdb_id: 8888})

      item =
        media_item_fixture(%{
          type: "tv_show",
          title: "Challenger",
          metadata_source: :tvdb,
          tvdb_id: 4244,
          tmdb_id: nil
        })

      Bypass.expect_once(bypass, "GET", "/tvdb/series/4244/extended", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "data" => %{
              "id" => 4244,
              "name" => "Challenger",
              "firstAired" => "2016-03-01",
              "overview" => "x",
              "genres" => [],
              "seasons" => [],
              "characters" => [],
              "trailers" => [%{"url" => "https://youtube.com/watch?v=b", "language" => "eng"}],
              "remoteIds" => [%{"sourceName" => "TheMovieDB.com", "id" => "8888", "type" => 12}]
            }
          })
        )
      end)

      {result, log} = with_log(fn -> Refresh.run(item, config: config, fetch_episodes: false) end)

      assert log =~ "[ExternalIds] tmdb_id 8888 is already owned by another media item"
      assert {:ok, updated} = result

      assert updated.tvdb_id == 4244
      assert updated.tmdb_id == nil
    end
  end
end
