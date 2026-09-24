defmodule Mydia.Metadata.Provider.RelayTvdbAlternativeTitlesTest do
  @moduledoc """
  TVDB series carry the names release groups actually use (a show's short
  name, its localized titles) in `aliases` and `translations.nameTranslations`.
  They must reach `MediaMetadata.alternative_titles`, which is where
  `Mydia.Indexers.ReleaseIdentity.Target` reads a show's other names from.
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

  test "aliases and name translations become alternative titles", ctx do
    stub_tvdb(ctx, %{
      "name" => "Quiet Harbor: The Long Tide",
      "aliases" => [
        %{"language" => "eng", "name" => "Quiet Harbor"},
        %{"language" => "fra", "name" => "Le Port Tranquille"},
        %{"language" => "jpn", "name" => "Quiet Harbor"},
        %{"language" => "eng", "name" => ""},
        %{"language" => "eng", "name" => nil}
      ],
      "translations" => %{
        "nameTranslations" => [
          %{"language" => "eng", "name" => "Quiet Harbor: The Long Tide"},
          %{"language" => "deu", "name" => "Stiller Hafen"},
          %{"language" => "fra", "name" => "Le Port Tranquille"}
        ],
        "overviewTranslations" => []
      }
    })

    assert {:ok, metadata} =
             Relay.fetch_by_ref(ctx.config, {:tvdb, ctx.tvdb_id}, media_type: :tv_show)

    assert metadata.title == "Quiet Harbor: The Long Tide"

    assert Enum.sort(metadata.alternative_titles) ==
             Enum.sort(["Quiet Harbor", "Le Port Tranquille", "Stiller Hafen"])
  end

  test "a series with neither field has no alternative titles", ctx do
    stub_tvdb(ctx, %{"name" => "Quiet Harbor", "aliases" => nil, "translations" => nil})

    assert {:ok, metadata} =
             Relay.fetch_by_ref(ctx.config, {:tvdb, ctx.tvdb_id}, media_type: :tv_show)

    assert metadata.alternative_titles == []
  end

  defp stub_tvdb(ctx, overrides) do
    data =
      Map.merge(
        %{
          "id" => ctx.tvdb_id,
          "name" => "Fixture Show",
          "overview" => "A show used to exercise alternative titles.",
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
