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

  test "is nil when TVDB has no ratings", ctx do
    for ratings <- [nil, [], [%{"name" => "", "country" => "usa"}]] do
      id = 900_000_000 + System.unique_integer([:positive])
      ctx = %{ctx | tvdb_id: id}
      stub_tvdb(ctx, %{"id" => id, "contentRatings" => ratings})

      assert {:ok, metadata} = Relay.fetch_by_ref(ctx.config, {:tvdb, id}, media_type: :tv_show)
      assert metadata.content_rating == nil
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
