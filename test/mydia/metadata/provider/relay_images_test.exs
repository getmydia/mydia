defmodule Mydia.Metadata.Provider.RelayImagesTest do
  @moduledoc """
  Offline coverage for the relay image listing: image language and TVDB posters
  (TVDB sends integer artwork type ids).
  """

  use ExUnit.Case, async: true

  alias Mydia.Metadata.Provider.Relay

  setup do
    bypass = Bypass.open()

    config = %{
      type: :metadata_relay,
      base_url: "http://localhost:#{bypass.port}",
      options: %{
        language: "en-US",
        include_adult: false,
        timeout: 2_000,
        connect_timeout: 1_000
      }
    }

    {:ok, bypass: bypass, config: config}
  end

  test "TMDB posters carry their language", %{bypass: bypass, config: config} do
    Bypass.expect_once(bypass, "GET", "/tmdb/movies/603/images", fn conn ->
      json(conn, %{
        "posters" => [%{"file_path" => "/a.jpg", "iso_639_1" => "en", "vote_average" => 5.1}],
        "backdrops" => [],
        "logos" => []
      })
    end)

    assert {:ok, %{posters: [p]}} =
             Relay.fetch_images_by_ref(config, {:tmdb, 603}, media_type: :movie)

    assert p.language == "en"
  end

  test "TVDB posters with integer type ids are listed", %{bypass: bypass, config: config} do
    Bypass.expect_once(bypass, "GET", "/tvdb/series/77/extended", fn conn ->
      json(conn, %{
        "data" => %{
          "artworks" => [
            %{"type" => 2, "image" => "https://artworks.thetvdb.com/p.jpg", "language" => "eng"},
            %{"type" => 3, "image" => "https://artworks.thetvdb.com/b.jpg"},
            %{"type" => 1, "image" => "https://artworks.thetvdb.com/banner.jpg"}
          ]
        }
      })
    end)

    assert {:ok, images} = Relay.fetch_images_by_ref(config, {:tvdb, 77}, [])

    assert [%{file_path: "https://artworks.thetvdb.com/p.jpg", language: "eng"}] = images.posters
    assert [%{file_path: "https://artworks.thetvdb.com/b.jpg"}] = images.backdrops
  end

  test "TVDB posters with named types still list", %{bypass: bypass, config: config} do
    Bypass.expect_once(bypass, "GET", "/tvdb/series/78/extended", fn conn ->
      json(conn, %{
        "data" => %{
          "artworks" => [
            %{"type" => "poster", "image" => "https://artworks.thetvdb.com/n.jpg"},
            %{"type" => %{"name" => "poster"}, "image" => "https://artworks.thetvdb.com/m.jpg"}
          ]
        }
      })
    end)

    assert {:ok, images} = Relay.fetch_images_by_ref(config, {:tvdb, 78}, [])

    assert Enum.map(images.posters, & &1.file_path) ==
             ["https://artworks.thetvdb.com/n.jpg", "https://artworks.thetvdb.com/m.jpg"]
  end

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(body))
  end
end
