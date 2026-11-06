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

  describe "linking TMDB person ids" do
    test "copies TMDB person ids onto TVDB cast by name", ctx do
      stub_cross_reference(ctx, [%{"id" => 501, "name" => "Marisol Ventura"}])

      assert {:ok, metadata} = fetch(ctx)
      assert %{"Marisol Ventura" => 501, "Bram Okafor" => nil} == ids_by_name(metadata)
      assert_received {:tmdb_append, "aggregate_credits"}
    end

    test "matches ignoring case and accents", ctx do
      stub_cross_reference(
        ctx,
        [%{"id" => 502, "name" => "Inés Duval"}],
        [{"Ines DUVAL", "Role A", 0}]
      )

      assert {:ok, metadata} = fetch(ctx)
      assert %{"Ines DUVAL" => 502} == ids_by_name(metadata)
    end

    test "leaves an ambiguous name unlinked", ctx do
      stub_cross_reference(ctx, [
        %{"id" => 503, "name" => "Marisol Ventura"},
        %{"id" => 504, "name" => "Marisol Ventura"}
      ])

      assert {:ok, metadata} = fetch(ctx)
      assert %{"Marisol Ventura" => nil, "Bram Okafor" => nil} == ids_by_name(metadata)
    end

    test "a failing TMDB lookup leaves the cast unlinked and the fetch succeeds", ctx do
      stub_cross_reference(ctx, :error)

      assert {:ok, metadata} = fetch(ctx)
      assert %{"Marisol Ventura" => nil, "Bram Okafor" => nil} == ids_by_name(metadata)
    end

    test "no TMDB cross-reference makes no extra request", ctx do
      stub_tvdb(ctx, %{"characters" => default_characters(), "remoteIds" => []})

      assert {:ok, metadata} = fetch(ctx)
      assert %{"Marisol Ventura" => nil, "Bram Okafor" => nil} == ids_by_name(metadata)
    end
  end

  defp fetch(ctx),
    do: Relay.fetch_by_ref(ctx.config, {:tvdb, ctx.tvdb_id}, media_type: :tv_show)

  defp ids_by_name(metadata), do: Map.new(metadata.cast, &{&1.name, &1.tmdb_person_id})

  defp default_characters do
    [
      character("Marisol Ventura", "Captain Quill", 0),
      character("Bram Okafor", "Teo Lark", 1)
    ]
  end

  # The metadata cache is process-global, so each test needs its own TMDB id.
  defp stub_cross_reference(ctx, tmdb_cast, characters \\ nil) do
    test_pid = self()
    tmdb_id = 800_000_000 + System.unique_integer([:positive])

    chars =
      case characters do
        nil -> default_characters()
        list -> for {n, role, sort} <- list, do: character(n, role, sort)
      end

    stub_tvdb(ctx, %{
      "characters" => chars,
      "remoteIds" => [%{"sourceName" => "TheMovieDB.com", "id" => Integer.to_string(tmdb_id)}]
    })

    Bypass.stub(ctx.bypass, "GET", "/tmdb/tv/shows/#{tmdb_id}", fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(test_pid, {:tmdb_append, conn.query_params["append_to_response"]})

      case tmdb_cast do
        :error ->
          Plug.Conn.resp(conn, 500, "boom")

        cast ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(
            200,
            Jason.encode!(%{"id" => tmdb_id, "aggregate_credits" => %{"cast" => cast}})
          )
      end
    end)

    tmdb_id
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
