defmodule Mydia.Metadata.Provider.RelayTvdbContentRatingsTest do
  @moduledoc """
  TVDB series carry content ratings under `contentRatings`, keyed by lowercase
  ISO 3166-1 alpha-3 country codes. They must reach
  `MediaMetadata.content_rating`, which prefers a US rating, then GB, then the
  first non-blank one it finds.
  """

  use ExUnit.Case, async: true

  alias Mydia.Metadata.Provider.Relay

  setup do
    bypass = Bypass.open()

    config = %{
      type: :metadata_relay,
      base_url: "http://localhost:#{bypass.port}",
      options: %{language: "en-US", include_adult: false, timeout: 2_000, connect_timeout: 1_000}
    }

    # Offset past any real id so the process-global metadata cache and
    # ProviderIDRegistry entries never collide with another test file's.
    tvdb_id = 900_000_000 + System.unique_integer([:positive])

    {:ok, bypass: bypass, config: config, tvdb_id: tvdb_id}
  end

  test "prefers the US rating", ctx do
    stub_tvdb(ctx, %{
      "contentRatings" => [
        %{"name" => "12", "country" => "deu"},
        %{"name" => "15", "country" => "gbr"},
        %{"name" => "TV-14", "country" => "usa"}
      ]
    })

    assert {:ok, metadata} =
             Relay.fetch_by_ref(ctx.config, {:tvdb, ctx.tvdb_id}, media_type: :tv_show)

    assert metadata.content_rating == "TV-14"
  end

  test "falls back to GB without a US rating", ctx do
    stub_tvdb(ctx, %{
      "contentRatings" => [
        %{"name" => "12", "country" => "deu"},
        %{"name" => "15", "country" => "gbr"}
      ]
    })

    assert {:ok, metadata} =
             Relay.fetch_by_ref(ctx.config, {:tvdb, ctx.tvdb_id}, media_type: :tv_show)

    assert metadata.content_rating == "15"
  end

  test "falls back to any rating, including an unmapped country", ctx do
    stub_tvdb(ctx, %{"contentRatings" => [%{"name" => "K-12", "country" => "zzz"}]})

    assert {:ok, metadata} =
             Relay.fetch_by_ref(ctx.config, {:tvdb, ctx.tvdb_id}, media_type: :tv_show)

    assert metadata.content_rating == "K-12"
  end

  test "skips a non-binary country instead of crashing", ctx do
    stub_tvdb(ctx, %{
      "contentRatings" => [
        %{"name" => "TV-PG", "country" => 840},
        %{"name" => "TV-14", "country" => "usa"}
      ]
    })

    assert {:ok, metadata} =
             Relay.fetch_by_ref(ctx.config, {:tvdb, ctx.tvdb_id}, media_type: :tv_show)

    assert metadata.content_rating == "TV-14"
  end

  test "is nil when TVDB has no ratings", ctx do
    for ratings <- [nil, [], [%{"name" => "", "country" => "usa"}]] do
      id = 900_000_000 + System.unique_integer([:positive])
      ctx = %{ctx | tvdb_id: id}
      stub_tvdb(ctx, %{"id" => id, "contentRatings" => ratings})

      assert {:ok, metadata} = Relay.fetch_by_ref(ctx.config, {:tvdb, id}, media_type: :tv_show)
      assert metadata.content_rating == nil
    end
  end

  describe "TMDB rating fallback" do
    import Mydia.MetadataCacheHelpers, only: [unique_provider_id: 0]
    import Mydia.RelayStubs

    setup do
      bypass = Bypass.open()
      %{bypass: bypass, config: relay_config(bypass)}
    end

    test "takes TMDB's rating when TVDB has none", ctx do
      tvdb_id = unique_provider_id()
      tmdb_id = unique_provider_id()
      stub_tvdb_series(ctx.bypass, tvdb_id, remote_tmdb_id: tmdb_id)
      stub_tmdb_tv(ctx.bypass, tmdb_id, certification: "TV-PG")

      assert {:ok, md} = Relay.fetch_by_ref(ctx.config, {:tvdb, tvdb_id}, media_type: :tv_show)
      assert md.content_rating == "TV-PG"
    end

    test "keeps TVDB's rating and does not ask TMDB", ctx do
      tvdb_id = unique_provider_id()
      tmdb_id = unique_provider_id()
      stub_tvdb_series(ctx.bypass, tvdb_id, certification: "TV-14", remote_tmdb_id: tmdb_id)
      stub_tmdb_tv(ctx.bypass, tmdb_id, certification: "TV-MA", test_pid: self())

      assert {:ok, md} = Relay.fetch_by_ref(ctx.config, {:tvdb, tvdb_id}, media_type: :tv_show)
      assert md.content_rating == "TV-14"
      refute_received {:relay_hit, "/tmdb/tv/shows/" <> _, ["content_ratings"]}
    end

    test "stays nil with no TMDB cross-reference", ctx do
      tvdb_id = unique_provider_id()
      stub_tvdb_series(ctx.bypass, tvdb_id)

      assert {:ok, md} = Relay.fetch_by_ref(ctx.config, {:tvdb, tvdb_id}, media_type: :tv_show)
      assert md.content_rating == nil
    end

    test "a failing TMDB lookup leaves the rating nil and the fetch ok", ctx do
      tvdb_id = unique_provider_id()
      tmdb_id = unique_provider_id()
      stub_tvdb_series(ctx.bypass, tvdb_id, remote_tmdb_id: tmdb_id)

      Bypass.stub(ctx.bypass, "GET", "/tmdb/tv/shows/#{tmdb_id}", fn conn ->
        Plug.Conn.resp(conn, 500, "boom")
      end)

      assert {:ok, md} = Relay.fetch_by_ref(ctx.config, {:tvdb, tvdb_id}, media_type: :tv_show)
      assert md.content_rating == nil
    end
  end

  defp stub_tvdb(ctx, overrides) do
    data =
      Map.merge(
        %{
          "id" => ctx.tvdb_id,
          "name" => "Fixture Show",
          "overview" => "A show used to exercise content ratings.",
          "firstAired" => "2016-07-15",
          "status" => %{"name" => "Continuing"},
          "originalLanguage" => "eng",
          "originalCountry" => "usa",
          "genres" => [],
          "seasons" => [
            %{
              "id" => 1_001,
              "number" => 1,
              "name" => "Season 1",
              "type" => %{"type" => "official"},
              "episodeCount" => 8
            }
          ],
          "translations" => %{"nameTranslations" => [], "overviewTranslations" => []},
          "remoteIds" => [],
          "trailers" => []
        },
        overrides
      )

    Bypass.stub(ctx.bypass, "GET", "/tvdb/series/#{ctx.tvdb_id}/extended", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"data" => data}))
    end)
  end
end
