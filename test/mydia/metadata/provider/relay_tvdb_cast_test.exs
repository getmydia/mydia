defmodule Mydia.Metadata.Provider.RelayTvdbCastTest do
  @moduledoc """
  TVDB series carry their cast under `characters`. It must reach
  `MediaMetadata.cast`, or every TVDB-sourced show renders without a Cast
  button.
  """

  use ExUnit.Case, async: true

  alias Mydia.Metadata.Provider.Relay
  alias Mydia.Metadata.Structs.CastMember

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

  test "maps actors in billing order", ctx do
    stub_tvdb(ctx, %{
      "characters" => [
        character("Orla Venn", "Captain Mara Quill", 2,
          personImgURL: "https://artworks.thetvdb.com/actor/2.jpg"
        ),
        character("Dax Morrow", "Teo Lark", 1, image: "https://artworks.thetvdb.com/actor/1.jpg"),
        character("Pell Arno", "Director", 0, peopleType: "Director"),
        character(nil, "Unnamed Guard", 3)
      ]
    })

    assert {:ok, metadata} =
             Relay.fetch_by_ref(ctx.config, {:tvdb, ctx.tvdb_id}, media_type: :tv_show)

    assert [
             %CastMember{
               name: "Dax Morrow",
               character: "Teo Lark",
               order: 0,
               profile_path: "https://artworks.thetvdb.com/actor/1.jpg"
             },
             %CastMember{
               name: "Orla Venn",
               character: "Captain Mara Quill",
               order: 1,
               profile_path: "https://artworks.thetvdb.com/actor/2.jpg"
             }
           ] = metadata.cast
  end

  test "is empty when TVDB sends no characters", ctx do
    stub_tvdb(ctx, %{"characters" => nil})

    assert {:ok, metadata} =
             Relay.fetch_by_ref(ctx.config, {:tvdb, ctx.tvdb_id}, media_type: :tv_show)

    assert metadata.cast in [nil, []]
  end

  defp character(person, role, sort, extra \\ []) do
    %{
      "personName" => person,
      "name" => role,
      "sort" => sort,
      "peopleType" => Keyword.get(extra, :peopleType, "Actor"),
      "personImgURL" => Keyword.get(extra, :personImgURL),
      "image" => Keyword.get(extra, :image)
    }
  end

  defp stub_tvdb(ctx, overrides) do
    data =
      Map.merge(
        %{
          "id" => ctx.tvdb_id,
          "name" => "Fixture Show",
          "overview" => "A show used to exercise the cast mapping.",
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
